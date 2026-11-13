# Category "Toàn bộ tệp" — every non-media file in shared storage

Status: **IMPLEMENTED, NOT TESTED ON DEVICES.**

Origin: device check 2026-11-13. On a non-Samsung phone, Smart Switch asks for "Quyền truy cập vào mọi tệp" (`MANAGE_EXTERNAL_STORAGE`) and for "Quyền truy cập dữ liệu sử dụng". Usage access only reveals which apps are used, so this app does not request it.

## How it works
- **Sender (Android 11+):**
  - The user turns on "Quyền truy cập vào mọi tệp" for Chuyển dữ liệu. The app opens that Settings page and checks again when the user returns.
  - The app walks shared storage and lists every readable file. It skips:
    - photos, videos and audio, because their own categories already cover them;
    - hidden files and folders;
    - `Android/data` and `Android/obb`, which stay blocked even with this permission.
  - Paths are sent as `Bộ nhớ/<original folder>/<name>`. Segments are sanitized and limited to 60 characters. Files whose path exceeds the protocol limit are skipped.
  - When a file is opened, its canonical path is checked to be inside shared storage (`FilesAdapter.resolve`).
- **Receiver:**
  - Android: files go to MediaStore Downloads as `Download/PhoneTransferPro/Bộ nhớ/<folder>/`, so the folder layout is kept. No permission is needed.
  - iPhone: files are saved into the Files app.
- Android 10 and iPhone cannot send this category: there is no All-files API on Android 10, and iOS has no such access.

## Not included
- App-private data: `/data/data` and `Android/data`.
- Data inside apps, such as chats and logins.
- `MANAGE_EXTERNAL_STORAGE` is restricted on Google Play. A Play build needs a policy declaration or must drop this category.

## Device test plan
1. Deny and then grant the permission on the Settings page. Check that the tile updates.
2. Transfer a mix of files (pdf, zip, apk, docx) in nested folders, plus a long Vietnamese file name. Check the folders on the receiver.
3. Confirm that no photo, video or audio files are duplicated when those categories are also selected.
4. Receive on an iPhone: the files must appear in the Files app.
