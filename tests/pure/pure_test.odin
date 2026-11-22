package pure_test

// Compile the small process-free suites once in full runs. Individual package entry points stay
// available for affected-package checks; -all-packages includes their tests through these imports.
@(require) import "../agent"
@(require) import "../draws"
@(require) import "../program_art"
