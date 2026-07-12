/* extractHAIRS is an allocate-and-exit batch tool (it never frees its variant/read structures),
 * so ASan's leak detector at exit would report a "leak" on every input. Disable LSan for this
 * target; ASan (memory errors) and UBSan stay fully on and halting. */
const char *__asan_default_options(void) {
    return "detect_leaks=0";
}
