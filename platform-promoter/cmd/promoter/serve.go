package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/twallac10/platform-promoter/internal/cluster"
	"github.com/twallac10/platform-promoter/internal/config"
	"github.com/twallac10/platform-promoter/internal/ledger"
	"github.com/twallac10/platform-promoter/internal/promote"
	"github.com/twallac10/platform-promoter/internal/server"
)

// serve runs in-cluster: it gates only the cluster it runs in (CLUSTER_NAME in
// tier TIER) and needs no credentials for any other cluster.
func serve(ctx context.Context, args []string) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fleetSrc := fs.String("fleet", envOr("PROMOTER_FLEET", ""), "platform-fleet dir or raw URL")
	tierName := fs.String("tier", os.Getenv("TIER"), "this cluster's tier")
	clusterName := fs.String("cluster", os.Getenv("CLUSTER_NAME"), "this cluster's name in tiers.yaml")
	listen := fs.String("listen", envOr("LISTEN", ":8080"), "HTTP listen address")
	interval := fs.Duration("interval", envDuration("RECHECK_INTERVAL", 10*time.Minute), "periodic re-check")
	kubeContext := fs.String("context", "", "use a kubeconfig context instead of in-cluster config (testing)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if *fleetSrc == "" || *tierName == "" || *clusterName == "" {
		return die(errors.New("serve needs --fleet/PROMOTER_FLEET, --tier/TIER and --cluster/CLUSTER_NAME"))
	}
	token, secret := os.Getenv("PROMOTER_TOKEN"), os.Getenv("WEBHOOK_TOKEN")
	if token == "" || secret == "" {
		return die(errors.New("PROMOTER_TOKEN and WEBHOOK_TOKEN are required"))
	}
	fleet, err := config.Load(*fleetSrc)
	if err != nil {
		return die(err)
	}
	tier, err := fleet.Tier(*tierName)
	if err != nil {
		return die(err)
	}
	if !contains(tier.Clusters, *clusterName) {
		return die(fmt.Errorf("cluster %q is not in tier %s (%v)", *clusterName, tier.Name, tier.Clusters))
	}
	gh := ledger.NewGitHub(fleet.Owner, token)
	own, err := cluster.FromContext(*kubeContext)
	if err != nil {
		return die(err)
	}
	own.Name = *clusterName
	p := &promote.Promoter{
		Fleet: fleet, Ledger: gh, Record: true, Out: os.Stdout,
		Contexts: []string{*clusterName}, // each tier attests for itself
		Connect: func(name string) (*cluster.Cluster, error) {
			if name != *clusterName {
				return nil, fmt.Errorf("refusing to reach cluster %s from %s", name, *clusterName)
			}
			return own, nil
		},
	}
	s := &server.Server{
		Promoter: p, Fleet: fleet, Ledger: gh, Tier: tier, Cluster: *clusterName,
		Secret: []byte(secret), Interval: *interval, Log: log,
	}
	srv := &http.Server{Addr: *listen, Handler: s.Handler(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(shutdown)
	}()
	go s.Run(ctx)
	log.Info("serving", "addr", *listen, "tier", tier.Name, "cluster", *clusterName, "recheck", interval.String())
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return die(err)
	}
	return 0
}

func envDuration(k string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(k)); err == nil {
		return v
	}
	return def
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
