package main

import (
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"
)

const (
	// How long a fetched key set is trusted before it is refreshed; the same
	// interval the sync server uses.
	jwksTTL = 6 * time.Hour
	// Minimum interval between fetches, so tokens with made-up key ids
	// cannot turn the gate into a request amplifier against the issuer.
	jwksRetryAfter = time.Minute
	jwksMaxBytes   = 1 << 20
)

var errKeysUnavailable = errors.New("signing keys unavailable")

// claims is the part of a token's payload the gate cares about.
type claims struct {
	Subject  string
	Username string
	Email    string
}

// verifier checks RS256 tokens against the issuer's published keys.
type verifier struct {
	issuer    string
	audiences map[string]struct{}
	jwksURL   string
	client    *http.Client
	now       func() time.Time

	mu          sync.Mutex
	keys        map[string]*rsa.PublicKey
	fetchedAt   time.Time // last successful fetch
	attemptedAt time.Time // last fetch attempt
}

func newVerifier(issuer string, clientIDs []string, jwksURL string) *verifier {
	audiences := make(map[string]struct{}, len(clientIDs))
	for _, id := range clientIDs {
		audiences[id] = struct{}{}
	}
	return &verifier{
		issuer:    issuer,
		audiences: audiences,
		jwksURL:   jwksURL,
		client:    &http.Client{Timeout: 10 * time.Second},
		now:       time.Now,
	}
}

type payload struct {
	Issuer    string          `json:"iss"`
	Audience  json.RawMessage `json:"aud"`
	ClientID  string          `json:"client_id"`
	Expires   *int64          `json:"exp"`
	NotBefore *int64          `json:"nbf"`
	Subject   string          `json:"sub"`
	Username  string          `json:"cognito:username"`
	Email     string          `json:"email"`
}

func (v *verifier) verify(token string) (*claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errors.New("not a compact JWS")
	}

	var header struct {
		Alg string `json:"alg"`
		Kid string `json:"kid"`
	}
	if err := decodeSegment(parts[0], &header); err != nil {
		return nil, fmt.Errorf("header: %w", err)
	}
	if header.Alg != "RS256" {
		return nil, fmt.Errorf("unsupported alg %q", header.Alg)
	}

	var p payload
	if err := decodeSegment(parts[1], &p); err != nil {
		return nil, fmt.Errorf("payload: %w", err)
	}

	// The cheap checks come first so junk never causes a key fetch.
	if p.Issuer != v.issuer {
		return nil, fmt.Errorf("issuer %q is not trusted", p.Issuer)
	}
	if !v.audienceAccepted(p) {
		return nil, errors.New("audience is not accepted")
	}
	now := v.now().Unix()
	if p.Expires == nil {
		return nil, errors.New("no exp claim")
	}
	if *p.Expires <= now {
		return nil, errors.New("expired")
	}
	if p.NotBefore != nil && *p.NotBefore > now {
		return nil, errors.New("not valid yet")
	}
	if p.Subject == "" {
		return nil, errors.New("no sub claim")
	}

	signature, err := decodeBase64URL(parts[2])
	if err != nil {
		return nil, fmt.Errorf("signature: %w", err)
	}
	key, err := v.key(header.Kid)
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if err := rsa.VerifyPKCS1v15(key, crypto.SHA256, digest[:], signature); err != nil {
		return nil, errors.New("signature does not verify")
	}

	return &claims{Subject: p.Subject, Username: p.Username, Email: p.Email}, nil
}

// audienceAccepted mirrors the sync server: Cognito id tokens name the app
// client in aud, access tokens in client_id.
func (v *verifier) audienceAccepted(p payload) bool {
	var audiences []string
	if len(p.Audience) > 0 {
		var one string
		var many []string
		if json.Unmarshal(p.Audience, &one) == nil {
			audiences = []string{one}
		} else if json.Unmarshal(p.Audience, &many) == nil {
			audiences = many
		}
	}
	if len(audiences) == 0 && p.ClientID != "" {
		audiences = []string{p.ClientID}
	}
	for _, a := range audiences {
		if _, ok := v.audiences[a]; ok {
			return true
		}
	}
	return false
}

// key returns the public key with the given id, fetching the key set when
// it is stale or does not have the id (keys rotate).
func (v *verifier) key(kid string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	defer v.mu.Unlock()

	now := v.now()
	if key, ok := v.keys[kid]; ok && now.Sub(v.fetchedAt) < jwksTTL {
		return key, nil
	}
	if now.Sub(v.attemptedAt) >= jwksRetryAfter {
		v.attemptedAt = now
		if err := v.fetchLocked(); err != nil {
			// Stale keys, if there are any, keep working until the issuer
			// is reachable again.
			log.Printf("fetching signing keys from %s failed: %v", v.jwksURL, err)
		} else {
			v.fetchedAt = now
		}
	}
	if key, ok := v.keys[kid]; ok {
		return key, nil
	}
	if len(v.keys) == 0 {
		return nil, errKeysUnavailable
	}
	return nil, fmt.Errorf("unknown key id %q", kid)
}

func (v *verifier) fetchLocked() error {
	resp, err := v.client.Get(v.jwksURL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	var jwks struct {
		Keys []struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			N   string `json:"n"`
			E   string `json:"e"`
		} `json:"keys"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, jwksMaxBytes)).Decode(&jwks); err != nil {
		return err
	}

	keys := make(map[string]*rsa.PublicKey, len(jwks.Keys))
	for _, k := range jwks.Keys {
		if k.Kty != "RSA" {
			continue
		}
		key, err := rsaPublicKey(k.N, k.E)
		if err != nil {
			return fmt.Errorf("key %q: %w", k.Kid, err)
		}
		keys[k.Kid] = key
	}
	if len(keys) == 0 {
		return errors.New("the key set has no RSA keys")
	}
	v.keys = keys
	return nil
}

func rsaPublicKey(n, e string) (*rsa.PublicKey, error) {
	modulus, err := decodeBase64URL(n)
	if err != nil {
		return nil, fmt.Errorf("n: %w", err)
	}
	exponentBytes, err := decodeBase64URL(e)
	if err != nil {
		return nil, fmt.Errorf("e: %w", err)
	}
	exponent := new(big.Int).SetBytes(exponentBytes)
	if !exponent.IsInt64() || exponent.Int64() < 3 || exponent.Int64() > math.MaxInt32 {
		return nil, errors.New("exponent out of range")
	}
	return &rsa.PublicKey{N: new(big.Int).SetBytes(modulus), E: int(exponent.Int64())}, nil
}

func decodeSegment(segment string, v any) error {
	data, err := decodeBase64URL(segment)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// decodeBase64URL accepts the unpadded encoding JWTs use, and tolerates
// padding.
func decodeBase64URL(s string) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(strings.TrimRight(s, "="))
}
