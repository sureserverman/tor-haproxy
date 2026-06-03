package main

// Persistent, accumulating bridge pool ("manage" mode, enabled by -pool).
//
// Goal: stop re-selecting bridges from scratch each run. Instead keep a durable
// pool of every bridge we've ever seen, fed from BOTH sources:
//   - Moat circumvention/builtin   (the static built-in obfs4 set)
//   - rdsys HTTPS distributor       (fresh, non-builtin community bridges;
//     https://bridges.torproject.org/bridges/en?transport=obfs4 — a plain GET,
//     no CAPTCHA, returns a small set that rotates slowly per requester, so
//     periodic runs accumulate new bridges over time)
// Each run: add newly-seen bridges, test the whole pool for real obfs4
// usability, mark reachable ones fresh, increment a fail counter on the rest,
// and PRUNE ONLY the persistently dead (failed >= -prune-fails consecutive
// runs AND not seen alive within -stale-days). The currently-reachable, fastest
// bridges are written to bridges.env for the proxy to consume.

import (
	"bufio"
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const rdsysURL = "https://bridges.torproject.org/bridges/en?transport=obfs4"

// tagRe strips HTML tags so obfs4 lines wrapped in markup parse cleanly.
var tagRe = regexp.MustCompile(`<[^>]*>`)

// fetchRdsys GETs the rdsys HTTPS distributor and returns obfs4 bridge lines.
// Uses the bootstrap resolver so it works at boot with no system DNS, and a
// browser-like User-Agent (the distributor varies output by client).
func fetchRdsys() ([]string, error) {
	client := &http.Client{
		Timeout:   30 * time.Second,
		Transport: &http.Transport{DialContext: bootstrapDialContext()},
	}
	req, err := http.NewRequest(http.MethodGet, rdsysURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("rdsys HTTP %d", resp.StatusCode)
	}
	raw := make([]byte, 0, 1<<20)
	buf := make([]byte, 32*1024)
	for len(raw) < (1 << 20) {
		n, e := resp.Body.Read(buf)
		raw = append(raw, buf[:n]...)
		if e != nil {
			break
		}
	}
	// Normalise the HTML: <br> -> newline, drop tags, decode entities, so the
	// obfs4 lines (which the page renders inside markup) become plain text.
	s := string(raw)
	s = strings.ReplaceAll(s, "<br>", "\n")
	s = strings.ReplaceAll(s, "<br/>", "\n")
	s = strings.ReplaceAll(s, "<br />", "\n")
	s = tagRe.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	return obfs4Re.FindAllString(s, -1), nil
}

// poolEntry is one bridge's durable state.
type poolEntry struct {
	line      string
	lastAlive int64 // unix seconds; 0 = never seen alive
	fails     int   // consecutive failed checks
	source    string
}

// loadPool reads the TSV pool file into a fingerprint-keyed map. Missing file
// is not an error (empty pool).
func loadPool(path string) map[string]*poolEntry {
	pool := make(map[string]*poolEntry)
	f, err := os.Open(path)
	if err != nil {
		return pool
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		ln := strings.TrimRight(sc.Text(), "\r\n")
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		// TSV: line \t lastAlive \t fails \t source
		parts := strings.Split(ln, "\t")
		if len(parts) < 1 || !bridgeRe.MatchString(parts[0]) {
			continue
		}
		e := &poolEntry{line: parts[0]}
		if len(parts) > 1 {
			e.lastAlive, _ = strconv.ParseInt(parts[1], 10, 64)
		}
		if len(parts) > 2 {
			e.fails, _ = strconv.Atoi(parts[2])
		}
		if len(parts) > 3 {
			e.source = parts[3]
		}
		if fpr := fieldN(e.line, 2); fpr != "" {
			pool[fpr] = e
		}
	}
	return pool
}

// savePool writes the pool back atomically (mode 0600).
func savePool(path string, pool map[string]*poolEntry) error {
	var b strings.Builder
	fmt.Fprintf(&b, "# bridge-eval pool — line<TAB>last_alive_unix<TAB>consecutive_fails<TAB>source\n")
	for _, e := range pool {
		fmt.Fprintf(&b, "%s\t%d\t%d\t%s\n", e.line, e.lastAlive, e.fails, e.source)
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".pool.*")
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
	return os.Rename(tmpName, path)
}

// runManage executes one accumulate/test/prune/select cycle.
func runManage(cfg config, poolPath, outPath string, count, pruneFails, staleDays int) error {
	pool := loadPool(poolPath)
	logf("pool: loaded %d known bridge(s) from %s", len(pool), poolPath)

	// --- Discover: merge both sources, add unseen fingerprints ---
	var fresh []string
	if m, err := fetchMoat(); err != nil {
		logf("  moat fetch failed: %v", err)
	} else {
		fresh = append(fresh, m...)
		logf("  moat builtin: %d candidate(s)", len(m))
	}
	if r, err := fetchRdsys(); err != nil {
		logf("  rdsys fetch failed: %v", err)
	} else {
		fresh = append(fresh, r...)
		logf("  rdsys distributor: %d candidate(s)", len(r))
	}
	added := 0
	for _, l := range dedupValid(fresh) {
		fpr := fieldN(l, 2)
		if _, ok := pool[fpr]; !ok {
			pool[fpr] = &poolEntry{line: l, source: "fetch"}
			added++
		}
	}
	logf("  added %d new bridge(s); pool now %d", added, len(pool))
	if len(pool) == 0 {
		return fmt.Errorf("pool empty and no candidates fetched")
	}

	// --- Test the whole pool for real obfs4 usability ---
	lines := make([]string, 0, len(pool))
	for _, e := range pool {
		lines = append(lines, e.line)
	}
	res := evaluateSet(lines, cfg)
	if res.startErr != "" {
		return fmt.Errorf("could not test pool: %s", res.startErr)
	}

	// --- Update state: reachable -> fresh; else fail++ ---
	now := time.Now().Unix()
	aliveN := 0
	for _, e := range pool {
		if _, ok := res.alive[ipOf(e.line)]; ok {
			e.fails = 0
			e.lastAlive = now
			aliveN++
		} else {
			e.fails++
		}
	}

	// --- Prune ONLY the persistently dead ---
	pruned := 0
	for fpr, e := range pool {
		stale := e.lastAlive == 0 || now-e.lastAlive > int64(staleDays)*86400
		if e.fails >= pruneFails && stale {
			logf("  pruned %s (fails=%d, never-recently-alive)", ipOf(e.line), e.fails)
			delete(pool, fpr)
			pruned++
		}
	}
	logf("pool: %d reachable / %d total this run; pruned %d", aliveN, len(pool)+pruned, pruned)

	if err := savePool(poolPath, pool); err != nil {
		logf("WARNING: could not save pool: %v", err)
	}

	// --- Select the currently-reachable, fastest bridges for the proxy ---
	selected := selectAlive(lines, res, count)
	if len(selected) == 0 {
		return fmt.Errorf("no reachable bridges this run (pool kept for next cycle)")
	}
	if len(selected) < 3 {
		logf("WARNING: only %d reachable bridge(s) — Tor Conflux needs 3; running without it.", len(selected))
	}
	return writeBridgesEnv(outPath, selected)
}
