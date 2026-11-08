/// PTP/1 constants. Must match docs/PROTOCOL_v1.md and tools/reference_peer/ptp_ref/core.py.
library;

const int protocolVersion = 1;
const List<int> supportedVersions = [1];

const int frameControl = 0x01;
const int frameData = 0x02;
const int dataHeaderSize = 12; // u32 fileIndex + u64 offset

const int maxControl = 64 * 1024;
const int maxManifest = 16 * 1024 * 1024;
const int maxChunk = 4 * 1024 * 1024;
const int maxDataFrame = 1 + dataHeaderSize + maxChunk;
const Set<String> largeControl = {'manifest', 'manifest_resp'};

const int maxFiles = 100000;
const int maxFileSize = 1 << 40;
const int defaultChunk = 1024 * 1024;
const int ackInterval = 8 * 1024 * 1024;
const int sendWindow = 32 * 1024 * 1024;

const Duration qrTtl = Duration(minutes: 5);
const Duration resumeWindow = Duration(minutes: 15);
const Duration handshakeTimeout = Duration(seconds: 20);
const Duration confirmTimeout = Duration(seconds: 120);
const Duration idleTimeout = Duration(seconds: 60);
const int maxAuthFailures = 5;

/// Bytes kept free on the receiving phone after a transfer.
const int storageReserve = 256 * 1024 * 1024;

/// Default iOS staging batch (see PROTOCOL_v1 §7 "Batches").
const int defaultBatchBytes = 2 * 1024 * 1024 * 1024;

const List<String> categoryIds = ['contacts', 'photos', 'videos', 'audio', 'documents', 'calendar'];
const List<String> platformIds = ['android', 'ios', 'desktop_reference'];
