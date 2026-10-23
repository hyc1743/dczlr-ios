# iOS interpreter compatibility check

This check runs only the self-authored `probes/win32_smoke.c` program. It is
separate from application or game compatibility. The interpreter build does
not require manually enabling JIT.

1. Sign and sideload the actual `PortLab-interpreter-unsigned.ipa` using your
   existing sideloading setup. Open **PortLab Interpreter**.
2. Open **Settings → Import root filesystem ZIP…** and select the supplied
   `TinyCore15Wine11.0.zip`. Import the ZIP as-is.
3. Return to the library and tap **Run Win32 compatibility check**. The first
   Wine launch can take time; the macOS host measurements are not phone timing
   predictions. The buffer is silent, so no test tone is expected.
4. Return to the library (stop the session if Wine remains open), then tap
   **View compatibility report**. A full
   pass contains all of these lines:

   ```text
   PORTLAB_WIN32_BEGIN
   PORTLAB_FILE_OK
   PORTLAB_THREAD_OK
   PORTLAB_GDI_PIXELS_OK
   PORTLAB_WAVE_BUFFER_OK
   PORTLAB_WIN32_OK
   ```

A partial report identifies how far execution reached. `PORTLAB_FAIL` records
an operation that failed. No report means the probe has not reached its report
creation, or its storage could not be opened; inspect **Logs** for launch errors.
The report is also available in the app's Files folder under
`RuntimeChecks/portlab-win32-result.txt`. Starting another check clears the
previous report. Its Wine prefix is `portlab-runtime-check`.

The pinned Wine ZIP is 162,748,254 bytes with SHA-256
`41835c49ce0e582a1d7a610243a8e4a95bc59996fb780c09705dc476bb9b6493`.
It is a separate runtime, not a resource part. Neither this check nor a full
pass establishes on-screen rendering, D3D9, audible playback, input handling,
game speed or playability. Normal Wine host shutdown is also a separate check.
