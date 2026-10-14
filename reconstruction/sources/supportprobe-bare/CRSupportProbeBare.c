/* Diagnostic-only bare dylib.
 *
 * No Foundation, libdispatch, notify, tweak backend, libcrane or libSandy.
 * The helper's mapped-image inspector is the observer; the constructor merely
 * makes the library non-empty and has no external side effects.
 */
static volatile unsigned long gCraneSupportProbeBareMarker;

__attribute__((constructor))
static void CRSupportProbeBareInit(void)
{
    gCraneSupportProbeBareMarker = 0x4352414EUL; /* "CRAN" */
}
