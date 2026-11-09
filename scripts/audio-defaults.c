// Saves and restores the default input, output and alert devices by UID, so installing or removing
// the AudioCap Hi-Res driver (which restarts coreaudiod) leaves them as they were.
//   audio-defaults show | save > FILE | restore FILE
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const AudioObjectPropertySelector kSelectors[] = {
    kAudioHardwarePropertyDefaultInputDevice,
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioHardwarePropertyDefaultSystemOutputDevice,
};
static const char *kNames[] = { "input", "output", "alert" };
enum { kCount = 3 };

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    return a;
}

static AudioObjectID defaultDevice(int i) {
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress a = address(kSelectors[i]);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &device) != noErr) return kAudioObjectUnknown;
    return device;
}

static int uidOf(AudioObjectID device, char *buffer, size_t length) {
    CFStringRef uid = NULL;
    UInt32 size = sizeof(uid);
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyDeviceUID);
    if (device == kAudioObjectUnknown || AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &uid) != noErr || uid == NULL) return 0;
    Boolean ok = CFStringGetCString(uid, buffer, (CFIndex)length, kCFStringEncodingUTF8);
    CFRelease(uid);
    return ok;
}

static AudioObjectID deviceForUID(const char *text) {
    CFStringRef uid = CFStringCreateWithCString(NULL, text, kCFStringEncodingUTF8);
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress a = address(kAudioHardwarePropertyTranslateUIDToDevice);
    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof(uid), &uid, &size, &device);
    CFRelease(uid);
    return err == noErr ? device : kAudioObjectUnknown;
}

static int show(void) {
    for (int i = 0; i < kCount; i++) {
        char uid[512] = "";
        uidOf(defaultDevice(i), uid, sizeof(uid));
        printf("%s\t%s\n", kNames[i], uid);
    }
    return 0;
}

// One pass: sets every default that differs from the saved UID. Returns how many still differ.
static int restorePass(char uids[kCount][512], int verbose) {
    int pending = 0;
    for (int i = 0; i < kCount; i++) {
        if (uids[i][0] == 0) continue;
        char current[512] = "";
        uidOf(defaultDevice(i), current, sizeof(current));
        if (strcmp(current, uids[i]) == 0) continue;
        AudioObjectID device = deviceForUID(uids[i]);
        if (device == kAudioObjectUnknown) { pending++; continue; }
        AudioObjectPropertyAddress a = address(kSelectors[i]);
        OSStatus err = AudioObjectSetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, sizeof(device), &device);
        if (err != noErr) pending++;
        else if (verbose) printf("Restored the default %s device (%s)\n", kNames[i], uids[i]);
    }
    return pending;
}

static int restore(const char *path) {
    FILE *file = fopen(path, "r");
    if (file == NULL) { perror(path); return 1; }
    char uids[kCount][512];
    memset(uids, 0, sizeof(uids));
    char line[600];
    while (fgets(line, sizeof(line), file)) {
        char *tab = strchr(line, '\t');
        if (tab == NULL) continue;
        *tab = 0;
        char *uid = tab + 1;
        uid[strcspn(uid, "\r\n")] = 0;
        for (int i = 0; i < kCount; i++) {
            if (strcmp(line, kNames[i]) == 0) snprintf(uids[i], sizeof(uids[i]), "%s", uid);
        }
    }
    fclose(file);
    // coreaudiod was just restarted: devices appear and macOS may pick new defaults for a few seconds.
    int pending = 1;
    for (int attempt = 0; attempt < 40; attempt++) {
        pending = restorePass(uids, 1);
        if (pending == 0 && attempt >= 8) break;
        usleep(250000);
    }
    if (pending > 0) fprintf(stderr, "Could not restore %d default device(s); check System Settings > Sound.\n", pending);
    return pending > 0 ? 2 : 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "show") == 0) return show();
    if (argc >= 2 && strcmp(argv[1], "save") == 0) return show();
    if (argc >= 3 && strcmp(argv[1], "restore") == 0) return restore(argv[2]);
    fprintf(stderr, "usage: audio-defaults show | save > FILE | restore FILE\n");
    return 64;
}
