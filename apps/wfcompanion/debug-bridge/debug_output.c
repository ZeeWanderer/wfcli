#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <string.h>

#define DBWIN_BUFFER_SIZE 4096

struct record_header {
    uint32_t pid;
    uint32_t length;
};

static int has_argument(const char *command_line, const char *argument)
{
    return strstr(command_line, argument) != NULL;
}

static int emit_test_message(void)
{
    OutputDebugStringA("wfcompanion DBWIN test message");
    return 0;
}

int main(void)
{
    HANDLE mapping;
    HANDLE buffer_ready;
    HANDLE data_ready;
    HANDLE output;
    unsigned char *buffer;

    if (has_argument(GetCommandLineA(), "--emit-test"))
        return emit_test_message();

    mapping = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
                                 DBWIN_BUFFER_SIZE, "DBWIN_BUFFER");
    buffer_ready = CreateEventA(NULL, FALSE, FALSE, "DBWIN_BUFFER_READY");
    data_ready = CreateEventA(NULL, FALSE, FALSE, "DBWIN_DATA_READY");
    if (!mapping || !buffer_ready || !data_ready)
        return 2;

    buffer = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, DBWIN_BUFFER_SIZE);
    output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (!buffer || output == INVALID_HANDLE_VALUE || output == NULL)
        return 3;

    for (;;) {
        DWORD status;
        DWORD written;
        uint32_t length = 0;
        struct record_header header;
        const char *message;

        if (!SetEvent(buffer_ready))
            return 4;
        status = WaitForSingleObject(data_ready, INFINITE);
        if (status != WAIT_OBJECT_0)
            return 5;

        header.pid = *(const uint32_t *)buffer;
        message = (const char *)(buffer + sizeof(uint32_t));
        while (length < DBWIN_BUFFER_SIZE - sizeof(uint32_t) && message[length] != '\0')
            ++length;
        header.length = length;

        if (!WriteFile(output, &header, sizeof(header), &written, NULL)
            || written != sizeof(header))
            return 6;
        if (length > 0
            && (!WriteFile(output, message, length, &written, NULL) || written != length))
            return 7;
    }
}
