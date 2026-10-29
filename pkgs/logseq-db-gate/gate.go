package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
)

type gate struct {
	verifier *verifier
	allow    atomic.Pointer[map[string]struct{}]
}

func (g *gate) allowed(sub string) bool {
	users := g.allow.Load()
	if users == nil {
		return false
	}
	_, ok := (*users)[sub]
	return ok
}

func (g *gate) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	method, uri := forwarded(r)
	path, query := splitURI(uri)

	// CORS preflights carry no credentials, and /health is public upstream.
	if method == http.MethodOptions || path == "/health" {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	token := bearerToken(r.Header.Get("Authorization"))
	if token == "" {
		// Browsers cannot set headers on WebSocket connections, so the
		// sync protocol also accepts the token in the query string.
		token = query.Get("token")
	}
	if token == "" {
		deny(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	c, err := g.verifier.verify(token)
	switch {
	case errors.Is(err, errKeysUnavailable):
		log.Printf("%s %s: cannot verify the token: %v", method, path, err)
		deny(w, http.StatusServiceUnavailable, "service unavailable")
		return
	case err != nil:
		log.Printf("%s %s: rejected the token: %v", method, path, err)
		deny(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	if !g.allowed(c.Subject) {
		log.Printf("%s %s: denied user %s (username %q, email %q): not on the allowlist",
			method, path, c.Subject, c.Username, c.Email)
		deny(w, http.StatusForbidden, "forbidden")
		return
	}

	w.Header().Set("X-Logseq-User-Id", c.Subject)
	w.WriteHeader(http.StatusNoContent)
}

// forwarded returns the method and URI of the request being authorized.
// Caddy's forward_auth and Traefik's ForwardAuth send them as
// X-Forwarded-Method and X-Forwarded-Uri; nginx's auth_request is usually
// configured to send X-Original-Method and X-Original-URI. Without them the
// gate's own request is used, which makes it easy to try out with curl.
func forwarded(r *http.Request) (method, uri string) {
	method = firstNonEmpty(r.Header.Get("X-Forwarded-Method"), r.Header.Get("X-Original-Method"), r.Method)
	uri = firstNonEmpty(r.Header.Get("X-Forwarded-Uri"), r.Header.Get("X-Original-URI"), r.URL.RequestURI())
	return method, uri
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

func splitURI(uri string) (path string, query url.Values) {
	u, err := url.ParseRequestURI(uri)
	if err != nil {
		return "", nil
	}
	return u.Path, u.Query()
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if len(header) > len(prefix) && strings.EqualFold(header[:len(prefix)], prefix) {
		return header[len(prefix):]
	}
	return ""
}

func deny(w http.ResponseWriter, status int, message string) {
	body, _ := json.Marshal(map[string]string{"error": message})
	h := w.Header()
	h.Set("Content-Type", "application/json")
	// The proxy relays this response to the client. The web app runs on
	// another origin, and without this header the browser would hide the
	// status from it.
	h.Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(status)
	w.Write(append(body, '\n'))
}
