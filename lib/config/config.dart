const FILE_TIMEOUT_DURATION = 5 * 60; // in seconds
const UPLOAD_DIRECTORY = './upload';

// Server-side secret used to sign delete tokens, share links, device
// fingerprints and exported message content so a client can't forge one
// without knowing this value.
const APP_SECRET = 'file-share-server-app-secret';

// Redundant on-disk backup locations a share's metadata bundle is mirrored
// to, alongside the primary upload directory -- the same resilience pattern
// already used for exports/reports (/export-archive, /export-job,
// /report-snapshot), just fanned out to more than one destination.
const BACKUP_MIRROR_DIRECTORIES = ['./backup_mirror_a', './backup_mirror_b'];
