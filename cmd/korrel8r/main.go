// Copyright: This file is part of korrel8r, released under https://github.com/korrel8r/korrel8r/blob/main/LICENSE

package main

import (
	_ "embed"
	"fmt"
	"os"

	"github.com/korrel8r/korrel8r/internal/pkg/logging"
	"github.com/korrel8r/korrel8r/internal/pkg/must"
	"github.com/korrel8r/korrel8r/internal/pkg/test/mock"
	"github.com/korrel8r/korrel8r/pkg/config"
	"github.com/korrel8r/korrel8r/pkg/domains/alert"
	"github.com/korrel8r/korrel8r/pkg/domains/k8s"
	logdomain "github.com/korrel8r/korrel8r/pkg/domains/log"
	"github.com/korrel8r/korrel8r/pkg/domains/metric"
	"github.com/korrel8r/korrel8r/pkg/engine"
	"github.com/spf13/cobra"
)

var (
	//go:embed version.txt
	version string

	rootCmd = &cobra.Command{
		Use:     "korrel8r",
		Short:   "Command line correlation tool",
		Version: version,
	}
	log = logging.Log()

	// Global Flags
	output        *string
	verbose       *int
	configuration *string
	panicOnErr    *bool

	// Korrel8r engine
	Engine *engine.Engine
)

const (
	configEnv     = "KORREL8R_CONFIG"
	defaultConfig = "/etc/korrel8r/korrel8r.yaml"
)

func init() {
	panicOnErr = rootCmd.PersistentFlags().Bool("panic", false, "panic on error instead of exit code 1")
	output = rootCmd.PersistentFlags().StringP("output", "o", "yaml", "Output format: [json, json-pretty, yaml]")
	verbose = rootCmd.PersistentFlags().IntP("verbose", "v", 0, "Verbosity for logging")
	configuration = rootCmd.PersistentFlags().StringP("config", "c", getConfig(), "Configuration file")
	cobra.OnInitialize(func() { logging.Init(*verbose) }) // Initialize logging after flags are parsed
	rootCmd.AddCommand(versionCmd)
}

// getConfig looks for the default configuration file.
func getConfig() string {
	if config, ok := os.LookupEnv(configEnv); ok {
		return config // Use env. var. if set.
	}
	return defaultConfig
}

func main() {
	defer func() {
		// Code in this package will panic with an error to cause an exit.
		if r := recover(); r != nil {
			fmt.Fprintln(os.Stderr, r)
			if *panicOnErr {
				panic(r)
			}
			os.Exit(1)
		}
		os.Exit(0)
	}()
	must.Must(rootCmd.Execute())
}

func newEngine() *engine.Engine {
	e := engine.New(k8s.Domain, logdomain.Domain, alert.Domain, metric.Domain, mock.Domain("mock"))
	c := must.Must1(config.Load(*configuration))
	must.Must(c.Apply(e))
	return e
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print version.",
	Run:   func(cmd *cobra.Command, args []string) { fmt.Println(rootCmd.Version) },
}
