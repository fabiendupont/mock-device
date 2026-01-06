package version

var (
	// Version is the driver version (set via ldflags during build)
	Version = "dev"

	// GitCommit is the git commit hash (set via ldflags during build)
	GitCommit = "unknown"
)

// GetVersion returns the version string
func GetVersion() string {
	return Version
}

// GetFullVersion returns version with git commit
func GetFullVersion() string {
	return Version + "-" + GitCommit
}
