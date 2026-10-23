/* Self-authored PE32 compatibility probe. No external application inputs. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

static FILE *report;

static void emit(const char *line) {
    puts(line);
    if (report) {
        fprintf(report, "%s\n", line);
        fflush(report);
    }
}

static int fail(const char *operation, unsigned long code) {
    printf("PORTLAB_FAIL %s code=%lu\n", operation, code);
    fflush(stdout);
    if (report) {
        fprintf(report, "PORTLAB_FAIL %s code=%lu\n", operation, code);
        fflush(report);
    }
    return 0;
}

static int file_probe(void) {
    char directory[MAX_PATH], path[MAX_PATH];
    const char payload[] = "PortLab private scratch roundtrip";
    DWORD count = 0;
    if (!GetTempPathA(sizeof(directory), directory) ||
        !GetTempFileNameA(directory, "plb", 0, path))
        return fail("temp-file", GetLastError());
    HANDLE file = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_TEMPORARY, NULL);
    int ok = file != INVALID_HANDLE_VALUE;
    if (ok) {
        char buffer[sizeof(payload)];
        ok = WriteFile(file, payload, sizeof(payload), &count, NULL) &&
             count == sizeof(payload) && FlushFileBuffers(file) &&
             SetFilePointer(file, 0, NULL, FILE_BEGIN) != INVALID_SET_FILE_POINTER &&
             ReadFile(file, buffer, sizeof(buffer), &count, NULL) &&
             count == sizeof(payload) && !memcmp(payload, buffer, sizeof(payload));
        CloseHandle(file);
    }
    if (!DeleteFileA(path)) ok = 0;
    if (!ok) return fail("file-roundtrip", GetLastError());
    emit("PORTLAB_FILE_OK");
    return 1;
}

static DWORD WINAPI worker(LPVOID parameter) {
    return SetEvent((HANDLE)parameter) ? 0x1743 : 1;
}

static int thread_probe(void) {
    HANDLE event = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!event) return fail("create-event", GetLastError());
    HANDLE thread = CreateThread(NULL, 0, worker, event, 0, NULL);
    DWORD result = 0;
    int ok = thread && WaitForSingleObject(event, 10000) == WAIT_OBJECT_0 &&
             WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0 &&
             GetExitCodeThread(thread, &result) && result == 0x1743;
    if (thread) CloseHandle(thread);
    CloseHandle(event);
    if (!ok) return fail("thread-event-join", GetLastError());
    emit("PORTLAB_THREAD_OK");
    return 1;
}

static int gdi_probe(void) {
    BITMAPINFO info = {0};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = 8;
    info.bmiHeader.biHeight = -8;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    DWORD *pixels = NULL;
    HDC dc = CreateCompatibleDC(NULL);
    if (!dc) return fail("create-memory-dc", GetLastError());
    HBITMAP bitmap = CreateDIBSection(dc, &info, DIB_RGB_COLORS,
                                     (void **)&pixels, NULL, 0);
    HBRUSH brush = CreateSolidBrush(RGB(0x12, 0x34, 0x56));
    HGDIOBJ previous = bitmap ? SelectObject(dc, bitmap) : NULL;
    RECT rect = {0, 0, 8, 8};
    int ok = bitmap && pixels && brush && previous && previous != HGDI_ERROR &&
             FillRect(dc, &rect, brush) && GdiFlush();
    if (ok) {
        for (int i = 0; i < 64; ++i)
            if ((pixels[i] & 0x00ffffff) != 0x00123456) ok = 0;
    }
    if (previous && previous != HGDI_ERROR) SelectObject(dc, previous);
    if (brush) DeleteObject(brush);
    if (bitmap) DeleteObject(bitmap);
    DeleteDC(dc);
    if (!ok) return fail("gdi-pixel-readback", GetLastError());
    emit("PORTLAB_GDI_PIXELS_OK");
    return 1;
}

static int audio_probe(void) {
    /* A bounded silent buffer tests completion, not audible playback. */
    WAVEFORMATEX format = {0};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = 1;
    format.nSamplesPerSec = 22050;
    format.wBitsPerSample = 16;
    format.nBlockAlign = 2;
    format.nAvgBytesPerSec = 44100;
    HWAVEOUT device = NULL;
    MMRESULT result = waveOutOpen(&device, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL);
    if (result != MMSYSERR_NOERROR) return fail("waveOutOpen", result);
    short samples[2205] = {0};
    WAVEHDR header = {0};
    header.lpData = (LPSTR)samples;
    header.dwBufferLength = sizeof(samples);
    result = waveOutPrepareHeader(device, &header, sizeof(header));
    int prepared = result == MMSYSERR_NOERROR;
    if (prepared) result = waveOutWrite(device, &header, sizeof(header));
    DWORD start = GetTickCount();
    while (result == MMSYSERR_NOERROR && !(header.dwFlags & WHDR_DONE) &&
           GetTickCount() - start < 10000) Sleep(10);
    int ok = result == MMSYSERR_NOERROR && (header.dwFlags & WHDR_DONE);
    if (!ok) waveOutReset(device);
    if (prepared && waveOutUnprepareHeader(device, &header, sizeof(header)) != MMSYSERR_NOERROR)
        ok = 0;
    if (waveOutClose(device) != MMSYSERR_NOERROR) ok = 0;
    if (!ok) return fail("wave-output-completion", result);
    emit("PORTLAB_WAVE_BUFFER_OK");
    return 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    report = fopen("portlab-win32-result.txt", "w");
    if (!report) {
        fail("open-diagnostic-report", (unsigned long)errno);
        return 1;
    }
    emit("PORTLAB_WIN32_BEGIN");
    int ok = file_probe();
    ok = thread_probe() && ok;
    ok = gdi_probe() && ok;
    ok = audio_probe() && ok;
    if (ok) emit("PORTLAB_WIN32_OK");
    fclose(report);
    return ok ? 0 : 1;
}
