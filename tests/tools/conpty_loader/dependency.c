/* Harmless loader fixture: no entry point, I/O, allocation or process creation. */
__declspec(dllexport) int fixture_dependency(void) { return 37; }
