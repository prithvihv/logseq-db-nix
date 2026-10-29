// Command logseq-db-gate is a forward-auth server that limits a Logseq DB
// sync server to an allowlist of user ids.
//
// A reverse proxy (Caddy's forward_auth, Traefik's ForwardAuth, nginx's
// auth_request) asks the gate about every request before passing it on to
// the sync server. The gate verifies the Logseq account token the client
// sent and answers 204 when the token's subject is on the allowlist, 401 when
// there is no valid token and 403 when the user is not allowed.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// Logseq's account pool, the one the official apps log in against.
const (
	defaultIssuer   = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_dtagLnju8"
	defaultClientID = "69cs1lgme7p8kbgld8n5kseii6"
)

type repeatable []string

func (r *repeatable) String() string     { return strings.Join(*r, ",") }
func (r *repeatable) Set(v string) error { *r = append(*r, v); return nil }

func main() {
	log.SetFlags(0)

	var userIDs, userIDFiles, clientIDs repeatable
	listen := flag.String("listen", "127.0.0.1:8788", "`address` to listen on; only the reverse proxy should be able to reach it")
	issuer := flag.String("issuer", defaultIssuer, "`iss` claim tokens must carry")
	jwksURL := flag.String("jwks-url", "", "`url` the issuer's signing keys are fetched from (default <issuer>/.well-known/jwks.json)")
	flag.Var(&userIDs, "allow-user-id", "user `id` allowed to use the sync server: the sub claim of their token; repeatable")
	flag.Var(&userIDFiles, "allow-user-ids-file", "`file` with one allowed user id per line; blank lines and # comments are skipped, SIGHUP re-reads it; repeatable")
	flag.Var(&clientIDs, "client-id", "`aud` (or client_id) claim tokens must carry; repeatable (default "+defaultClientID+")")
	flag.Parse()

	if flag.NArg() > 0 {
		fmt.Fprintf(os.Stderr, "logseq-db-gate: unexpected argument %q\n", flag.Arg(0))
		flag.Usage()
		os.Exit(2)
	}
	if len(clientIDs) == 0 {
		clientIDs = repeatable{defaultClientID}
	}
	if *jwksURL == "" {
		*jwksURL = strings.TrimSuffix(*issuer, "/") + "/.well-known/jwks.json"
	}

	g := &gate{verifier: newVerifier(*issuer, clientIDs, *jwksURL)}
	reload := func() (int, error) {
		users, err := loadAllowlist(userIDs, userIDFiles)
		if err != nil {
			return 0, err
		}
		g.allow.Store(&users)
		return len(users), nil
	}
	n, err := reload()
	if err != nil {
		log.Fatalf("logseq-db-gate: %v", err)
	}
	if n == 0 {
		log.Print("warning: no user ids are allowed (see -allow-user-id and -allow-user-ids-file), every user will be denied")
	}

	hup := make(chan os.Signal, 1)
	signal.Notify(hup, syscall.SIGHUP)
	go func() {
		for range hup {
			n, err := reload()
			if err != nil {
				log.Printf("reload failed, keeping the previous allowlist: %v", err)
				continue
			}
			log.Printf("reloaded the allowlist: %d user ids", n)
		}
	}()

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("logseq-db-gate: %v", err)
	}
	log.Printf("listening on %s; %d allowed user ids; accepting tokens issued by %s", ln.Addr(), n, *issuer)

	srv := &http.Server{Handler: g, ReadHeaderTimeout: 10 * time.Second}
	log.Fatalf("logseq-db-gate: %v", srv.Serve(ln))
}
