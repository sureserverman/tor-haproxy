// Command bridge-eval tests candidate obfs4 bridges the way Tor actually uses
// them — as one set, in a single tor process — and selects the most
// responsive N for nice-dns (writes bridges.env consumed by tor-haproxy /
// tor-socat start.sh).
//
// Why this exists: the previous selection ranked bridges by raw TCP-connect
// latency, which cannot distinguish an obfs4-working bridge from one that is
// "TCP-open but PT-dead" (accepts the SYN, never completes the obfs4
// handshake). An earlier version of this tool over-corrected by bootstrapping
// each bridge *in isolation, in parallel, with a tight timeout* — which
// produced false negatives: a bridge that is a perfectly good guard within a
// set cannot necessarily solo-fetch the whole directory alone in the window,
// and N parallel tor+lyrebird bootstraps starve each other / trip per-source
// bridge limits. Tor uses bridges as a SET. So this version launches ONE tor
// with all candidates and records which bridges actually complete the obfs4
// handshake (Tor logs "new bridge descriptor ... at <IP>" — per-bridge
// attribution even in a combined run). Aliveness, not solo-bootstrap speed, is
// the signal; a single onion connect through the whole tor is reported as a
// set-level health note, never used to discard an otherwise-alive bridge.
//
// Pure standard library (no external modules), so CGO_ENABLED=0 static builds
// cross-compile cleanly to linux/amd64, linux/arm (armv7), linux/arm64 and
// linux/riscv64. It shells out to `tor` and an obfs4 pluggable-transport binary
// (lyrebird/obfs4proxy), which both proxy images already ship.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	moatURL = "https://bridges.torproject.org/moat/circumvention/builtin"
	// Cloudflare's DoT v3 onion (matches the MapAddress in the image torrc).
	defaultOnion = "dns4torpnlfs2ifuz2s2yf3fc7rdmsbhm6rw75euj35pac6ap25zgqad.onion"
)

// A syntactically valid container-side obfs4 line (unquoted, as --env-file /
// EnvironmentFile require). Mirrors the regex in start.sh / fetch-bridges.sh.
var bridgeRe = regexp.MustCompile(`^obfs4 \S+:\d+ [0-9A-Fa-f]{40} cert=\S+ iat-mode=[012]$`)

// obfs4Re extracts candidate obfs4 lines from an arbitrary Moat JSON payload
// without depending on the exact JSON-API envelope shape.
var obfs4Re = regexp.MustCompile(`obfs4 [0-9.]+:[0-9]+ [0-9A-Fa-f]{40} cert=[^"\\ ]+ iat-mode=[012]`)

// descRe captures the bridge IP from Tor's notice:
//
//	"new bridge descriptor '<nick>' (fresh): $<fpr>~<nick> [...] at 1.2.3.4"
//
// Its appearance means the obfs4 handshake to that bridge completed and Tor
// has a usable descriptor for it. (Requires SafeLogging 0 so the IP is shown.)
var descRe = regexp.MustCompile(`new bridge descriptor.*\bat ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)`)

type config struct {
	torBin    string
	ptBin     string
	window    time.Duration // total time budget for the combined bootstrap
	grace     time.Duration // extra time after 100% to catch straggler descriptors
	port      int           // SOCKS port for the combined tor
	onion     string        // set-level reachability target ("" disables)
	onionPort int
}

type setResult struct {
	alive        map[string]time.Duration // bridge IP -> time of first descriptor
	bootstrapped bool
	bootTime     time.Duration
	onionOK      bool
	onionLat     time.Duration
	onionErr     string
	startErr     string // tor failed to start at all
}

func main() {
	fs := flag.NewFlagSet("bridge-eval", flag.ContinueOnError)
	outPathP := fs.String("out", "", "write bridges.env here (default: stdout)")
	countP := fs.Int("count", 3, "number of bridges to select (Conflux wants 3)")
	minSelP := fs.Int("min", 1, "fail unless at least this many bridges are alive")
	windowP := fs.Int("window", 150, "total seconds to let the combined tor bootstrap")
	graceP := fs.Int("grace", 20, "extra seconds after Bootstrapped 100% to catch straggler bridges")
	candFileP := fs.String("candidates", "", "file of 'obfs4 ...' (or BRIDGEn=...) lines (default: fetch from Moat)")
	torBinP := fs.String("tor", "tor", "path to the tor binary")
	ptBinP := fs.String("pt", "", "path to obfs4 PT binary (default: lyrebird/obfs4proxy on PATH)")
	onionP := fs.String("onion", defaultOnion, "set-level .onion reachability target (informational)")
	noOnionP := fs.Bool("no-onion", false, "skip the onion reachability check")
	portP := fs.Int("port", 29050, "SOCKS port for the evaluation tor")
	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(2)
	}
	outPath, count, minSel := *outPathP, *countP, *minSelP
	candFile, torBin, ptBin := *candFileP, *torBinP, *ptBinP
	onion, noOnion, port := *onionP, *noOnionP, *portP

	pt := ptBin
	if pt == "" {
		if pt = findPT(); pt == "" {
			fatal("no obfs4 pluggable-transport binary found (looked for lyrebird, obfs4proxy); pass -pt")
		}
	}
	if _, err := exec.LookPath(torBin); err != nil {
		fatal("tor binary %q not found: %v", torBin, err)
	}

	var candidates []string
	var err error
	if candFile != "" {
		candidates, err = readCandidates(candFile)
	} else {
		logf("fetching candidate obfs4 bridges from Moat (bootstrap-resolved)...")
		candidates, err = fetchMoat()
	}
	if err != nil {
		fatal("gathering candidates: %v", err)
	}
	candidates = dedupValid(candidates)
	if len(candidates) == 0 {
		fatal("no syntactically valid obfs4 candidates")
	}

	cfg := config{
		torBin:    torBin,
		ptBin:     pt,
		window:    time.Duration(*windowP) * time.Second,
		grace:     time.Duration(*graceP) * time.Second,
		port:      port,
		onionPort: 853,
	}
	if !noOnion {
		cfg.onion = onion
	}

	logf("evaluating %d candidate bridge(s) as one set (window %ds)...", len(candidates), *windowP)
	res := evaluateSet(candidates, cfg)
	if res.startErr != "" {
		fatal("could not start tor: %s", res.startErr)
	}
	report(candidates, res, cfg)

	selected := selectAlive(candidates, res, count)
	if len(selected) < minSel {
		fatal("only %d bridge(s) completed an obfs4 handshake; need at least %d (use better/private bridges)",
			len(selected), minSel)
	}
	if !res.bootstrapped {
		logf("WARNING: the set did not reach Bootstrapped 100%% within the window; selecting by")
		logf("         handshake aliveness anyway, but these bridges may be slow to bootstrap.")
	}
	if cfg.onion != "" && !res.onionOK {
		logf("WARNING: could not reach %s through the set (%s) — bridges are alive but the", cfg.onion, res.onionErr)
		logf("         onion path was unreachable in this run (often transient); selecting anyway.")
	}
	if len(selected) < count {
		logf("WARNING: only %d of %d requested bridges are alive from this network.", len(selected), count)
		logf("         Writing the working set — better than padding with dead bridges, but Tor")
		logf("         Conflux needs %d link-disjoint guards. Add more/better bridges to restore it.", count)
	}

	if err := writeBridgesEnv(outPath, selected); err != nil {
		fatal("writing output: %v", err)
	}
}

// evaluateSet launches a single tor with all candidate bridges and records,
// from its notice log, which bridges completed the obfs4 handshake (emitted a
// descriptor) and how quickly, whether the set reached 100%, and — once it
// did — whether a circuit to the target onion can be built through the set.
func evaluateSet(candidates []string, cfg config) setResult {
	res := setResult{alive: map[string]time.Duration{}}

	dir, err := os.MkdirTemp("", "bridge-eval-")
	if err != nil {
		res.startErr = "mktemp: " + err.Error()
		return res
	}
	defer os.RemoveAll(dir)

	var sb strings.Builder
	fmt.Fprintf(&sb, "DataDirectory %s/data\n", dir)
	fmt.Fprintf(&sb, "SocksPort 127.0.0.1:%d\n", cfg.port)
	sb.WriteString("UseBridges 1\n")
	sb.WriteString("SafeLogging 0\n") // so "new bridge descriptor ... at <IP>" shows the IP
	fmt.Fprintf(&sb, "ClientTransportPlugin obfs4 exec %s\n", cfg.ptBin)
	for _, l := range candidates {
		fmt.Fprintf(&sb, "Bridge %s\n", l)
	}
	sb.WriteString("Log notice stdout\n")
	torrcPath := filepath.Join(dir, "torrc")
	if err := os.WriteFile(torrcPath, []byte(sb.String()), 0o600); err != nil {
		res.startErr = "write torrc: " + err.Error()
		return res
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.window)
	defer cancel()
	cmd := exec.CommandContext(ctx, cfg.torBin, "-f", torrcPath)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		res.startErr = "stdout pipe: " + err.Error()
		return res
	}
	cmd.Stderr = nil // notices go to stdout via "Log notice stdout"

	start := time.Now()
	if err := cmd.Start(); err != nil {
		res.startErr = "start tor: " + err.Error()
		return res
	}

	var mu sync.Mutex
	bootCh := make(chan time.Duration, 1)
	scanDone := make(chan struct{})
	go func() {
		defer close(scanDone)
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			line := sc.Text()
			if m := descRe.FindStringSubmatch(line); m != nil {
				mu.Lock()
				if _, ok := res.alive[m[1]]; !ok {
					res.alive[m[1]] = time.Since(start)
				}
				mu.Unlock()
			}
			if strings.Contains(line, "Bootstrapped 100%") {
				select {
				case bootCh <- time.Since(start):
				default:
				}
			}
		}
	}()

	// Wait for the set to bootstrap (or the window to expire). Once up, probe
	// the onion and then linger briefly to collect straggler descriptors from
	// slower-but-alive bridges that Tor didn't need to reach 100%.
	select {
	case bt := <-bootCh:
		res.bootstrapped = true
		res.bootTime = bt
		if cfg.onion != "" {
			if lat, err := socksConnectLatency(fmt.Sprintf("127.0.0.1:%d", cfg.port), cfg.onion, cfg.onionPort, 30*time.Second); err == nil {
				res.onionOK = true
				res.onionLat = lat
			} else {
				res.onionErr = err.Error()
			}
		}
		select {
		case <-time.After(cfg.grace):
		case <-ctx.Done():
		}
	case <-ctx.Done():
		// never reached 100%; whatever handshaked is still recorded as alive
	}

	cancel()
	_ = cmd.Wait()
	<-scanDone // ensure the scanner finished writing res.alive before we read it

	mu.Lock()
	snapshot := make(map[string]time.Duration, len(res.alive))
	for k, v := range res.alive {
		snapshot[k] = v
	}
	mu.Unlock()
	res.alive = snapshot
	return res
}

// selectAlive returns up to count alive bridges, fastest-handshake first.
func selectAlive(candidates []string, res setResult, count int) []string {
	type entry struct {
		line string
		t    time.Duration
	}
	var alive []entry
	for _, l := range candidates {
		if t, ok := res.alive[ipOf(l)]; ok {
			alive = append(alive, entry{l, t})
		}
	}
	sort.SliceStable(alive, func(i, j int) bool { return alive[i].t < alive[j].t })
	if len(alive) > count {
		alive = alive[:count]
	}
	out := make([]string, len(alive))
	for i, e := range alive {
		out[i] = e.line
	}
	return out
}

func report(candidates []string, res setResult, cfg config) {
	if res.bootstrapped {
		if cfg.onion == "" {
			logf("  set bootstrapped in %dms", res.bootTime.Milliseconds())
		} else if res.onionOK {
			logf("  set bootstrapped in %dms; onion reachable in %dms", res.bootTime.Milliseconds(), res.onionLat.Milliseconds())
		} else {
			logf("  set bootstrapped in %dms; onion unreachable (%s)", res.bootTime.Milliseconds(), res.onionErr)
		}
	} else {
		logf("  set did NOT reach Bootstrapped 100%% within the window")
	}
	for _, l := range candidates {
		ip := ipOf(l)
		if t, ok := res.alive[ip]; ok {
			logf("  ✓ %-21s obfs4 handshake OK, descriptor in %dms", ip, t.Milliseconds())
		} else {
			logf("  ✗ %-21s no obfs4 handshake (dead)", ip)
		}
	}
}

func writeBridgesEnv(outPath string, selected []string) error {
	var b strings.Builder
	fmt.Fprintf(&b, "# Auto-generated by bridge-eval on %s\n", time.Now().UTC().Format(time.RFC3339))
	fmt.Fprintf(&b, "# Method: combined Tor obfs4 bootstrap; kept bridges that completed the\n")
	fmt.Fprintf(&b, "# handshake (emitted a descriptor), ranked fastest-first.\n")
	fmt.Fprintf(&b, "# Format: KEY=VALUE  (NO surrounding quotes — podman --env-file does not strip them)\n")
	for i, line := range selected {
		fmt.Fprintf(&b, "BRIDGE%d=%s\n", i+1, line)
	}
	if outPath == "" || outPath == "-" {
		_, err := os.Stdout.WriteString(b.String())
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(outPath), ".bridges.env.*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if _, err := tmp.WriteString(b.String()); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, outPath); err != nil {
		return err
	}
	logf("wrote %s with %d bridge(s)", outPath, len(selected))
	return nil
}

// --- Moat fetch (bootstrap-resolved) ---------------------------------------

// fetchMoat POSTs the Moat builtin-circumvention request and extracts obfs4
// lines. It resolves bridges.torproject.org via public resolvers rather than
// the system resolver, because at boot the system resolver is the very
// nice-dns stack this run is trying to bring up (resolv.conf -> 127.0.0.1).
func fetchMoat() ([]string, error) {
	client := &http.Client{
		Timeout:   30 * time.Second,
		Transport: &http.Transport{DialContext: bootstrapDialContext()},
	}
	body := strings.NewReader(`{"data":[{"version":"0.1.0","type":"moat-circumvention"}]}`)
	req, err := http.NewRequest(http.MethodPost, moatURL, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/vnd.api+json")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("moat HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return obfs4Re.FindAllString(string(data), -1), nil
}

// bootstrapDialContext resolves hostnames via 1.1.1.1/9.9.9.9/8.8.8.8 (UDP 53)
// independently of /etc/resolv.conf, then dials the resulting IP. Falls back
// to the default resolver if the public resolvers are unreachable.
func bootstrapDialContext() func(context.Context, string, string) (net.Conn, error) {
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 4 * time.Second}
			var lastErr error
			for _, srv := range []string{"1.1.1.1:53", "9.9.9.9:53", "8.8.8.8:53"} {
				if c, err := d.DialContext(ctx, "udp", srv); err == nil {
					return c, nil
				} else {
					lastErr = err
				}
			}
			return nil, lastErr
		},
	}
	dialer := net.Dialer{Timeout: 10 * time.Second}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			return nil, err
		}
		if net.ParseIP(host) != nil {
			return dialer.DialContext(ctx, network, addr)
		}
		ips, err := resolver.LookupHost(ctx, host)
		if err != nil || len(ips) == 0 {
			return dialer.DialContext(ctx, network, addr) // fall back to system resolver
		}
		return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0], port))
	}
}

// --- minimal SOCKS5 client (no external deps) ------------------------------

// socksConnectLatency performs a SOCKS5 CONNECT to host:port through socksAddr
// and returns the time to a successful reply. Success means Tor built a
// working circuit (here, an onion rendezvous) to the destination.
func socksConnectLatency(socksAddr, host string, port int, timeout time.Duration) (time.Duration, error) {
	start := time.Now()
	c, err := net.DialTimeout("tcp", socksAddr, timeout)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(timeout))

	if _, err := c.Write([]byte{0x05, 0x01, 0x00}); err != nil { // greeting: v5, no-auth
		return 0, err
	}
	rep := make([]byte, 2)
	if _, err := io.ReadFull(c, rep); err != nil {
		return 0, err
	}
	if rep[0] != 0x05 || rep[1] != 0x00 {
		return 0, fmt.Errorf("unexpected method selection %v", rep)
	}
	if len(host) > 255 {
		return 0, fmt.Errorf("hostname too long")
	}
	req := []byte{0x05, 0x01, 0x00, 0x03, byte(len(host))} // CONNECT, domain-name
	req = append(req, host...)
	req = append(req, byte(port>>8), byte(port&0xff))
	if _, err := c.Write(req); err != nil {
		return 0, err
	}
	head := make([]byte, 4)
	if _, err := io.ReadFull(c, head); err != nil {
		return 0, err
	}
	if head[1] != 0x00 {
		return 0, fmt.Errorf("connect failed, reply code %d", head[1])
	}
	switch head[3] { // drain bound address so the reply is fully consumed
	case 0x01:
		io.CopyN(io.Discard, c, 4+2)
	case 0x03:
		l := make([]byte, 1)
		if _, err := io.ReadFull(c, l); err == nil {
			io.CopyN(io.Discard, c, int64(l[0])+2)
		}
	case 0x04:
		io.CopyN(io.Discard, c, 16+2)
	}
	return time.Since(start), nil
}

// --- helpers ---------------------------------------------------------------

func readCandidates(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Accept "BRIDGE1=obfs4 ..." or a bare "obfs4 ..." line.
		if i := strings.IndexByte(line, '='); i >= 0 && strings.HasPrefix(line[i+1:], "obfs4 ") {
			line = line[i+1:]
		}
		out = append(out, line)
	}
	return out, sc.Err()
}

func dedupValid(lines []string) []string {
	seen := make(map[string]bool)
	var out []string
	for _, l := range lines {
		l = strings.TrimSpace(l)
		if !bridgeRe.MatchString(l) {
			continue
		}
		fpr := fieldN(l, 2) // fingerprint
		if fpr == "" || seen[fpr] {
			continue
		}
		seen[fpr] = true
		out = append(out, l)
	}
	return out
}

func ipOf(line string) string {
	hp := fieldN(line, 1) // IP:PORT
	if i := strings.LastIndexByte(hp, ':'); i >= 0 {
		return hp[:i]
	}
	return hp
}

// fieldN returns the n-th whitespace field (0-indexed) of s, or "".
func fieldN(s string, n int) string {
	f := strings.Fields(s)
	if n < len(f) {
		return f[n]
	}
	return ""
}

func findPT() string {
	for _, name := range []string{"lyrebird", "obfs4proxy"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	for _, p := range []string{"/usr/bin/lyrebird", "/usr/bin/obfs4proxy"} {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	return ""
}

func logf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
}

func fatal(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "bridge-eval: "+format+"\n", a...)
	os.Exit(1)
}
