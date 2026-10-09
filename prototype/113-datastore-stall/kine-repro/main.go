// Repro for k3d-lab#113: kine's compaction fatals with "Transaction commit failed"
// when its transaction outlives the compact timeout. Another SQLite writer holds the
// write lock for -hold while compaction runs with -timeout.
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/k3s-io/kine/pkg/drivers"
	"github.com/k3s-io/kine/pkg/drivers/sqlite"
	"github.com/sirupsen/logrus"
)

func main() {
	timeout := flag.Duration("timeout", 500*time.Millisecond, "kine's compact timeout (k3s: 5s)")
	hold := flag.Duration("hold", 0, "how long another writer holds SQLite's write lock before compaction")
	revs := flag.Int("revs", 200, "revisions for compaction to delete")
	keys := flag.Int("keys", 1, "keys the revisions are spread over")
	flag.Parse()

	dir, _ := os.MkdirTemp("", "kine-repro")
	defer os.RemoveAll(dir)
	dsn := filepath.Join(dir, "state.db") + "?" + sqlite.DefaultParams
	ctx := context.Background()
	var wg sync.WaitGroup
	backend, _, err := sqlite.NewVariant(ctx, &wg, "sqlite3", &drivers.Config{
		DataSourceName: dsn, CompactTimeout: *timeout, CompactBatchSize: 1000, CompactMinRetain: 10,
	})
	must(err)
	must(backend.Start(ctx))

	// Revisions for compaction to delete: one key updated many times.
	last := make([]int64, *keys)
	for k := range last {
		last[k], err = backend.Create(ctx, fmt.Sprintf("/registry/x/%d", k), []byte("v"), 0)
		must(err)
	}
	var rev int64
	for i := 0; i < *revs; i++ {
		k := i % *keys
		rev, _, _, err = backend.Update(ctx, fmt.Sprintf("/registry/x/%d", k), make([]byte, 2048), last[k], 0)
		must(err)
		last[k] = rev
	}

	// Another writer, as k3s has many, holds the write lock.
	other, err := sql.Open("sqlite3", filepath.Join(dir, "state.db")+"?_busy_timeout=30000")
	must(err)
	tx, err := other.Begin()
	must(err)
	_, err = tx.Exec("UPDATE kine SET value = value WHERE id = 1")
	must(err)
	if *hold > 0 {
		go func() { time.Sleep(*hold); must(tx.Commit()) }()
	} else {
		must(tx.Commit())
	}

	logrus.Infof("compacting to %d, timeout %s, lock held %s", rev, *timeout, *hold)
	_, err = backend.Compact(ctx, rev)
	logrus.Infof("compaction returned: %v", err)
	fmt.Println("SURVIVED")
}

func must(err error) {
	if err != nil {
		logrus.Fatalf("harness: %v", err)
	}
}
