#pragma once

// Scene media (looping GIF + MP3) downloaded from the public Supabase Storage
// bucket "scene-media" into the watch's flash (FFat), once, then reused offline.
//   flash path:  /video/ocean.gif   /audio/rain.mp3
//   LVGL path:   A:/video/ocean.gif (LV_FS_POSIX, rooted at /ffat)

// Network task, once per cycle: downloads anything the current profile needs
// that is not in flash yet. Does nothing when everything is present.
void media_sync();

// Network task: download one file into flash if it is not there yet.
void media_ensure(const char *path);

// True if the file exists in flash (path like "/video/ocean.gif").
bool media_has(const char *path);
