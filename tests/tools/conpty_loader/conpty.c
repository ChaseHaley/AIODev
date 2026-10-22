/* These names are inspected, never called as a real ConPTY API. */
__declspec(dllimport) int fixture_dependency(void);
__declspec(dllexport) int FixtureReachDependency(void) { return fixture_dependency(); }
#ifndef MISSING_EXPORTS
__declspec(dllexport) int ConptyCreatePseudoConsole(void) { return fixture_dependency(); }
__declspec(dllexport) void ConptyResizePseudoConsole(void) { }
__declspec(dllexport) void ConptyClosePseudoConsole(void) { }
#endif
