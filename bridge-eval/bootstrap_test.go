package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestDohLookupParsesA verifies the DoH JSON path extracts A records, ignores
// non-A answers (e.g. CNAME), and is driven entirely offline via httptest.
func TestDohLookupParsesA(t *testing.T) {
	var gotName, gotAccept string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotName = r.URL.Query().Get("name")
		gotAccept = r.Header.Get("Accept")
		w.Header().Set("Content-Type", "application/dns-json")
		io.WriteString(w, `{"Status":0,"Answer":[`+
			`{"name":"bridges.example.","type":5,"data":"cname.example."},`+ // CNAME, must be ignored
			`{"name":"bridges.example.","type":1,"data":"93.184.216.34"},`+
			`{"name":"bridges.example.","type":1,"data":"1.2.3.4"}]}`)
	}))
	defer srv.Close()

	saved := dohEndpoints
	dohEndpoints = []string{srv.URL}
	defer func() { dohEndpoints = saved }()

	ips := dohLookup(context.Background(), "bridges.example")
	if len(ips) != 2 || ips[0] != "93.184.216.34" || ips[1] != "1.2.3.4" {
		t.Fatalf("expected the two A records, got %v", ips)
	}
	if gotName != "bridges.example" {
		t.Errorf("query name not forwarded: got %q", gotName)
	}
	if gotAccept != "application/dns-json" {
		t.Errorf("Accept header not set: got %q", gotAccept)
	}
}

// TestDohLookupFailsClosed verifies a non-200 endpoint yields no IPs (so the
// caller falls through to UDP/53, then the system resolver).
func TestDohLookupFailsClosed(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	saved := dohEndpoints
	dohEndpoints = []string{srv.URL}
	defer func() { dohEndpoints = saved }()

	if ips := dohLookup(context.Background(), "bridges.example"); ips != nil {
		t.Fatalf("expected nil on HTTP 503, got %v", ips)
	}
}
