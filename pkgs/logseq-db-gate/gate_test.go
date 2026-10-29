package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	testIssuer   = "https://issuer.test"
	testClientID = "test-client"
	alice        = "11111111-1111-4111-8111-111111111111"
	mallory      = "22222222-2222-4222-8222-222222222222"
)

type fixture struct {
	t       *testing.T
	key     *rsa.PrivateKey
	gate    *gate
	now     time.Time
	fetches atomic.Int32

	mu        sync.Mutex
	published []*rsa.PrivateKey // keys the JWKS endpoint serves, by kid "k0", "k1", ...
	down      bool
}

func newFixture(t *testing.T, allowed ...string) *fixture {
	t.Helper()
	f := &fixture{t: t, key: generateKey(t), now: time.Date(2026, 10, 26, 12, 0, 0, 0, time.UTC)}
	f.published = []*rsa.PrivateKey{f.key}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.fetches.Add(1)
		f.mu.Lock()
		defer f.mu.Unlock()
		if f.down {
			http.Error(w, "nope", http.StatusInternalServerError)
			return
		}
		var keys []map[string]string
		for i, k := range f.published {
			keys = append(keys, map[string]string{
				"kty": "RSA",
				"kid": kid(i),
				"n":   base64.RawURLEncoding.EncodeToString(k.N.Bytes()),
				"e":   base64.RawURLEncoding.EncodeToString(big.NewInt(int64(k.E)).Bytes()),
			})
		}
		json.NewEncoder(w).Encode(map[string]any{"keys": keys})
	}))
	t.Cleanup(server.Close)

	v := newVerifier(testIssuer, []string{testClientID}, server.URL)
	v.now = func() time.Time { return f.now }
	f.gate = &gate{verifier: v}
	users, err := loadAllowlist(allowed, nil)
	if err != nil {
		t.Fatal(err)
	}
	f.gate.allow.Store(&users)
	return f
}

func kid(i int) string { return "k" + string(rune('0'+i)) }

func generateKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// token mints an id token for alice, signed with the published key, with
// the given changes applied to the header and payload.
func (f *fixture) token(edit ...func(header, payload map[string]any)) string {
	header := map[string]any{"alg": "RS256", "kid": kid(0), "typ": "JWT"}
	payload := map[string]any{
		"iss":              testIssuer,
		"aud":              testClientID,
		"sub":              alice,
		"cognito:username": "alice",
		"email":            "alice@example.test",
		"token_use":        "id",
		"exp":              f.now.Add(time.Hour).Unix(),
	}
	key := f.key
	for _, e := range edit {
		e(header, payload)
	}
	if k, ok := header["signing-key"].(*rsa.PrivateKey); ok {
		key = k
		delete(header, "signing-key")
	}
	return sign(f.t, key, header, payload)
}

func sign(t *testing.T, key *rsa.PrivateKey, header, payload map[string]any) string {
	t.Helper()
	h, _ := json.Marshal(header)
	p, _ := json.Marshal(payload)
	signingInput := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(p)
	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(signature)
}

// request simulates Caddy's forward_auth: a GET to the gate carrying the
// original method and URI in headers, plus the client's headers.
func (f *fixture) request(method, uri string, headers ...string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodGet, "/verify", nil)
	r.Header.Set("X-Forwarded-Method", method)
	r.Header.Set("X-Forwarded-Uri", uri)
	for i := 0; i+1 < len(headers); i += 2 {
		r.Header.Set(headers[i], headers[i+1])
	}
	w := httptest.NewRecorder()
	f.gate.ServeHTTP(w, r)
	return w
}

func bearer(token string) []string { return []string{"Authorization", "Bearer " + token} }

func expectStatus(t *testing.T, w *httptest.ResponseRecorder, status int) {
	t.Helper()
	if w.Code != status {
		t.Fatalf("got %d %s, want %d", w.Code, strings.TrimSpace(w.Body.String()), status)
	}
}

func TestAllowedUserPasses(t *testing.T) {
	f := newFixture(t, alice)
	w := f.request("GET", "/graphs", bearer(f.token())...)
	expectStatus(t, w, http.StatusNoContent)
	if got := w.Header().Get("X-Logseq-User-Id"); got != alice {
		t.Fatalf("X-Logseq-User-Id = %q, want %q", got, alice)
	}
}

func TestTokenInQueryString(t *testing.T) {
	f := newFixture(t, alice)
	expectStatus(t, f.request("GET", "/sync/g1/ws?token="+f.token()), http.StatusNoContent)
	expectStatus(t, f.request("GET", "/sync/g1/ws?token="+f.token(as(mallory))), http.StatusForbidden)
}

func TestAccessTokenShape(t *testing.T) {
	f := newFixture(t, alice)
	accessToken := f.token(func(_, p map[string]any) {
		delete(p, "aud")
		p["client_id"] = testClientID
		p["token_use"] = "access"
	})
	expectStatus(t, f.request("GET", "/graphs", bearer(accessToken)...), http.StatusNoContent)

	arrayAud := f.token(func(_, p map[string]any) { p["aud"] = []string{"other", testClientID} })
	expectStatus(t, f.request("GET", "/graphs", bearer(arrayAud)...), http.StatusNoContent)
}

func TestUnlistedUserIsForbidden(t *testing.T) {
	f := newFixture(t, alice)
	w := f.request("POST", "/graphs", bearer(f.token(as(mallory)))...)
	expectStatus(t, w, http.StatusForbidden)
	if body := strings.TrimSpace(w.Body.String()); body != `{"error":"forbidden"}` {
		t.Fatalf("body = %s", body)
	}
	if w.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatal("denials need CORS headers so the web app can read the status")
	}
}

func TestEmptyAllowlistDeniesEveryone(t *testing.T) {
	f := newFixture(t)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusForbidden)
}

func TestMissingToken(t *testing.T) {
	f := newFixture(t, alice)
	expectStatus(t, f.request("GET", "/graphs"), http.StatusUnauthorized)
	expectStatus(t, f.request("GET", "/graphs", "Authorization", "Basic abc"), http.StatusUnauthorized)
	expectStatus(t, f.request("GET", "/graphs?token="), http.StatusUnauthorized)
	if f.fetches.Load() != 0 {
		t.Fatal("no key fetch should happen without a token")
	}
}

func TestPublicRequests(t *testing.T) {
	f := newFixture(t)
	expectStatus(t, f.request("GET", "/health"), http.StatusNoContent)
	expectStatus(t, f.request("OPTIONS", "/graphs", "Origin", "https://app.example"), http.StatusNoContent)
	expectStatus(t, f.request("GET", "/healthz"), http.StatusUnauthorized)
	expectStatus(t, f.request("GET", "/health/../graphs"), http.StatusUnauthorized)
}

func TestForwardedHeadersAreOptional(t *testing.T) {
	f := newFixture(t, alice)
	direct := func(method, uri string, headers ...string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, uri, nil)
		for i := 0; i+1 < len(headers); i += 2 {
			r.Header.Set(headers[i], headers[i+1])
		}
		w := httptest.NewRecorder()
		f.gate.ServeHTTP(w, r)
		return w
	}
	expectStatus(t, direct("GET", "/health"), http.StatusNoContent)
	expectStatus(t, direct("OPTIONS", "/graphs"), http.StatusNoContent)
	expectStatus(t, direct("GET", "/graphs?token="+f.token()), http.StatusNoContent)
	expectStatus(t, direct("GET", "/graphs"), http.StatusUnauthorized)
	// nginx's auth_request convention.
	expectStatus(t, direct("GET", "/", "X-Original-URI", "/health"), http.StatusNoContent)
	expectStatus(t, direct("GET", "/", "X-Original-Method", "OPTIONS", "X-Original-URI", "/graphs"), http.StatusNoContent)
}

func TestRejectedTokens(t *testing.T) {
	f := newFixture(t, alice)
	rogue := generateKey(t)
	cases := map[string]string{
		"garbage":          "not.a.jwt",
		"two segments":     "eyJhbGciOiJSUzI1NiJ9.e30",
		"alg none":         f.token(func(h, _ map[string]any) { h["alg"] = "none" }),
		"alg HS256":        f.token(func(h, _ map[string]any) { h["alg"] = "HS256" }),
		"wrong issuer":     f.token(func(_, p map[string]any) { p["iss"] = "https://evil.test" }),
		"wrong audience":   f.token(func(_, p map[string]any) { p["aud"] = "other-client" }),
		"no audience":      f.token(func(_, p map[string]any) { delete(p, "aud") }),
		"expired":          f.token(func(_, p map[string]any) { p["exp"] = f.now.Unix() }),
		"no exp":           f.token(func(_, p map[string]any) { delete(p, "exp") }),
		"not yet valid":    f.token(func(_, p map[string]any) { p["nbf"] = f.now.Add(time.Minute).Unix() }),
		"no sub":           f.token(func(_, p map[string]any) { delete(p, "sub") }),
		"unknown kid":      f.token(func(h, _ map[string]any) { h["kid"] = "k9" }),
		"forged signature": f.token(func(h, _ map[string]any) { h["signing-key"] = rogue }),
		"tampered payload": tamper(f.token()),
	}
	for name, token := range cases {
		t.Run(name, func(t *testing.T) {
			expectStatus(t, f.request("GET", "/graphs", bearer(token)...), http.StatusUnauthorized)
		})
	}
}

// tamper swaps the subject in a signed token without re-signing it.
func tamper(token string) string {
	parts := strings.Split(token, ".")
	payload, _ := base64.RawURLEncoding.DecodeString(parts[1])
	payload = []byte(strings.Replace(string(payload), alice, mallory, 1))
	parts[1] = base64.RawURLEncoding.EncodeToString(payload)
	return strings.Join(parts, ".")
}

func TestKeyRotation(t *testing.T) {
	f := newFixture(t, alice)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)
	if f.fetches.Load() != 1 {
		t.Fatalf("fetches = %d, want 1", f.fetches.Load())
	}

	// A token signed with a key the gate has not seen triggers a fetch, but
	// the issuer has not published it yet.
	next := generateKey(t)
	withNext := func(h, _ map[string]any) { h["kid"] = kid(1); h["signing-key"] = next }
	f.now = f.now.Add(jwksRetryAfter)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token(withNext))...), http.StatusUnauthorized)
	if f.fetches.Load() != 2 {
		t.Fatalf("fetches = %d, want 2", f.fetches.Load())
	}

	// Now it is published, but the gate backs off between fetches.
	f.mu.Lock()
	f.published = append(f.published, next)
	f.mu.Unlock()
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token(withNext))...), http.StatusUnauthorized)
	if f.fetches.Load() != 2 {
		t.Fatalf("fetches = %d, want 2 (rate limited)", f.fetches.Load())
	}

	f.now = f.now.Add(jwksRetryAfter)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token(withNext))...), http.StatusNoContent)
	if f.fetches.Load() != 3 {
		t.Fatalf("fetches = %d, want 3", f.fetches.Load())
	}
	// The old key still works as long as it is published.
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)
}

func TestKeySetIsRefreshedAfterTTL(t *testing.T) {
	f := newFixture(t, alice)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)
	f.now = f.now.Add(jwksTTL)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)
	if f.fetches.Load() != 2 {
		t.Fatalf("fetches = %d, want 2", f.fetches.Load())
	}
}

func TestStaleKeysOutliveAnIssuerOutage(t *testing.T) {
	f := newFixture(t, alice)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)

	f.mu.Lock()
	f.down = true
	f.mu.Unlock()
	f.now = f.now.Add(jwksTTL)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)
	if f.fetches.Load() != 2 {
		t.Fatalf("fetches = %d, want 2", f.fetches.Load())
	}
}

func TestNoKeysAtAll(t *testing.T) {
	f := newFixture(t, alice)
	f.mu.Lock()
	f.down = true
	f.mu.Unlock()
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusServiceUnavailable)
	// Junk is still rejected outright, without waiting for the issuer.
	expectStatus(t, f.request("GET", "/graphs", bearer("junk")...), http.StatusUnauthorized)
	// Back off before trying the issuer again.
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusServiceUnavailable)
	if f.fetches.Load() != 1 {
		t.Fatalf("fetches = %d, want 1", f.fetches.Load())
	}

	f.mu.Lock()
	f.down = false
	f.mu.Unlock()
	f.now = f.now.Add(jwksRetryAfter)
	expectStatus(t, f.request("GET", "/graphs", bearer(f.token())...), http.StatusNoContent)
}

func TestLoadAllowlist(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "users")
	content := "# people who may sync\n\n  " + alice + "   # alice\n" + mallory + "\n\n"
	if err := os.WriteFile(file, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	users, err := loadAllowlist([]string{" bob ", ""}, []string{file})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{alice, mallory, "bob"}
	if len(users) != len(want) {
		t.Fatalf("users = %v, want %v", users, want)
	}
	for _, id := range want {
		if _, ok := users[id]; !ok {
			t.Fatalf("%q missing from %v", id, users)
		}
	}

	if _, err := loadAllowlist(nil, []string{filepath.Join(dir, "missing")}); err == nil {
		t.Fatal("a missing file must be an error")
	}
}

func as(sub string) func(header, payload map[string]any) {
	return func(_, p map[string]any) {
		p["sub"] = sub
		p["cognito:username"] = "mallory"
		p["email"] = "mallory@example.test"
	}
}
