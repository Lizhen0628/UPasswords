const BLOCK_SIZE = 512;
const OCTAL_SIZE_LIMIT = 0o77777777777;
const MAX_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAX_MEMBER_BYTES = 128 * 1024 * 1024;
const REQUIRED_PATHS = ["Info.json", "Manifest.sealed", "Snapshot.upw", "Snapshot.upwkey"];
const UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";

export class PortableBackupArchiveError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "PortableBackupArchiveError";
    }
}

/** Build the native-compatible, uncompressed USTAR archive without buffering payloads together. */
export function createPortableBackupArchive(files: ReadonlyMap<string, Blob | Uint8Array>): Blob {
    const paths = [...files.keys()].sort();
    if (paths.length < REQUIRED_PATHS.length || REQUIRED_PATHS.some(path => !files.has(path))) {
        throw new PortableBackupArchiveError("invalid_package");
    }

    const parts: BlobPart[] = [];
    let archiveSize = BLOCK_SIZE * 2;
    for (const path of paths) {
        if (!isSupportedPackagePath(path)) throw new PortableBackupArchiveError("unsupported_path");
        const value = files.get(path);
        if (!value) throw new PortableBackupArchiveError("invalid_package");
        const size = value instanceof Blob ? value.size : value.byteLength;
        if (!Number.isSafeInteger(size) || size < 0 || size > OCTAL_SIZE_LIMIT || size > MAX_MEMBER_BYTES) {
            throw new PortableBackupArchiveError("file_too_large");
        }
        archiveSize += BLOCK_SIZE + size + paddingSize(size);
        if (archiveSize > MAX_ARCHIVE_BYTES) throw new PortableBackupArchiveError("file_too_large");
        parts.push(makeHeader(path, size));
        if (value instanceof Blob) {
            parts.push(value);
        } else {
            const copy = new Uint8Array(value.byteLength);
            copy.set(value);
            parts.push(copy.buffer as ArrayBuffer);
        }
        const padding = paddingSize(size);
        if (padding) parts.push(new Uint8Array(padding).buffer as ArrayBuffer);
    }
    parts.push(new Uint8Array(BLOCK_SIZE * 2).buffer as ArrayBuffer);
    return new Blob(parts, { type: "application/octet-stream" });
}

/** Validate a complete archive before returning zero-copy Blob slices for its members. */
export async function readPortableBackupArchive(archive: Blob): Promise<Map<string, Blob>> {
    if (archive.size > MAX_ARCHIVE_BYTES) throw new PortableBackupArchiveError("invalid_archive");
    const files = new Map<string, Blob>();
    let offset = 0;
    let terminated = false;

    while (offset + BLOCK_SIZE <= archive.size) {
        const header = new Uint8Array(await archive.slice(offset, offset + BLOCK_SIZE).arrayBuffer());
        offset += BLOCK_SIZE;
        if (header.every(byte => byte === 0)) {
            if (offset + BLOCK_SIZE > archive.size) throw new PortableBackupArchiveError("invalid_archive");
            const second = new Uint8Array(await archive.slice(offset, offset + BLOCK_SIZE).arrayBuffer());
            if (second.some(byte => byte !== 0)) throw new PortableBackupArchiveError("invalid_archive");
            offset += BLOCK_SIZE;
            await requireZeroPadding(archive, offset);
            terminated = true;
            break;
        }

        const entry = parseHeader(header);
        if (!isSupportedPackagePath(entry.path) || files.has(entry.path)
            || !Number.isSafeInteger(entry.size) || entry.size < 0 || entry.size > MAX_MEMBER_BYTES) {
            throw new PortableBackupArchiveError("invalid_archive");
        }
        const end = offset + entry.size;
        if (!Number.isSafeInteger(end) || end > archive.size) {
            throw new PortableBackupArchiveError("invalid_archive");
        }
        files.set(entry.path, archive.slice(offset, end));
        offset = end;

        const padding = paddingSize(entry.size);
        if (offset + padding > archive.size) throw new PortableBackupArchiveError("invalid_archive");
        if (padding) {
            const bytes = new Uint8Array(await archive.slice(offset, offset + padding).arrayBuffer());
            if (bytes.some(byte => byte !== 0)) throw new PortableBackupArchiveError("invalid_archive");
        }
        offset += padding;
    }

    if (!terminated || files.size < REQUIRED_PATHS.length
        || REQUIRED_PATHS.some(path => !files.has(path))) {
        throw new PortableBackupArchiveError("invalid_archive");
    }
    return files;
}

function makeHeader(path: string, size: number): ArrayBuffer {
    const parts = splitPath(path);
    const header = new Uint8Array(BLOCK_SIZE);
    writeString(parts.name, header, 0, 100);
    writeOctal(0o600, header, 100, 108);
    writeOctal(0, header, 108, 116);
    writeOctal(0, header, 116, 124);
    writeOctal(size, header, 124, 136);
    writeOctal(0, header, 136, 148);
    header.fill(32, 148, 156);
    header[156] = 48;
    writeString("ustar", header, 257, 262);
    writeString("00", header, 263, 265);
    writeString(parts.prefix, header, 345, 500);

    const checksum = header.reduce((sum, byte) => sum + byte, 0);
    if (checksum > 0o777777) throw new PortableBackupArchiveError("invalid_package");
    const digits = checksum.toString(8).padStart(6, "0");
    writeString(digits, header, 148, 154);
    header[154] = 0;
    header[155] = 32;
    return header.buffer as ArrayBuffer;
}

function parseHeader(header: Uint8Array): { path: string; size: number } {
    if (header.length !== BLOCK_SIZE || !matches(header, 257, "ustar\0")
        || !matches(header, 263, "00") || header[156] !== 0 && header[156] !== 48) {
        throw new PortableBackupArchiveError("invalid_archive");
    }
    const declared = parseOctal(header.subarray(148, 156));
    const checksumHeader = header.slice();
    checksumHeader.fill(32, 148, 156);
    if (declared !== checksumHeader.reduce((sum, byte) => sum + byte, 0)) {
        throw new PortableBackupArchiveError("invalid_archive");
    }

    const name = readString(header.subarray(0, 100));
    const prefix = readString(header.subarray(345, 500));
    const path = prefix ? `${prefix}/${name}` : name;
    return { path, size: parseOctal(header.subarray(124, 136)) };
}

function isSupportedPackagePath(path: string): boolean {
    if (!path || path.startsWith("/") || path.includes("\\")
        || [...path].some(character => character.charCodeAt(0) < 1 || character.charCodeAt(0) >= 128)) {
        return false;
    }
    const components = path.split("/");
    if (components.some(part => !part || part === "." || part === "..")) return false;
    if (REQUIRED_PATHS.includes(path)) return true;
    if (components.length === 2 && components[0] === "Attachments") {
        return new RegExp(`^${UUID_PATTERN}-${UUID_PATTERN}\\.cipher$`).test(components[1]);
    }
    if (components.length === 3 && components[0] === "Conflicts") {
        return /^[0-9a-f]{32}$/.test(components[1])
            && /^[0-9a-f]{32}\.cipher$/.test(components[2]);
    }
    return false;
}

function splitPath(path: string): { name: string; prefix: string } {
    if (new TextEncoder().encode(path).length <= 100) return { name: path, prefix: "" };
    for (let index = path.lastIndexOf("/"); index > 0; index = path.lastIndexOf("/", index - 1)) {
        const prefix = path.slice(0, index);
        const name = path.slice(index + 1);
        if (new TextEncoder().encode(prefix).length <= 155
            && new TextEncoder().encode(name).length <= 100) return { name, prefix };
    }
    throw new PortableBackupArchiveError("invalid_package");
}

function writeString(value: string, bytes: Uint8Array, start: number, end: number): void {
    const encoded = new TextEncoder().encode(value);
    if (encoded.length > end - start || encoded.some(byte => byte < 1 || byte >= 128)) {
        throw new PortableBackupArchiveError("invalid_package");
    }
    bytes.set(encoded, start);
}

function writeOctal(value: number, bytes: Uint8Array, start: number, end: number): void {
    const encoded = value.toString(8).padStart(end - start - 1, "0");
    if (encoded.length !== end - start - 1) throw new PortableBackupArchiveError("file_too_large");
    writeString(encoded, bytes, start, end - 1);
}

function readString(bytes: Uint8Array): string {
    const end = bytes.indexOf(0);
    const content = bytes.subarray(0, end < 0 ? bytes.length : end);
    if (content.some(byte => byte < 1 || byte >= 128)) {
        throw new PortableBackupArchiveError("invalid_archive");
    }
    return new TextDecoder("ascii").decode(content);
}

function parseOctal(bytes: Uint8Array): number {
    const start = bytes.findIndex(byte => byte !== 0 && byte !== 32);
    if (start < 0) return 0;
    let end = bytes.length;
    while (end > start && (bytes[end - 1] === 0 || bytes[end - 1] === 32)) end--;
    let result = 0;
    for (let index = start; index < end; index++) {
        const byte = bytes[index];
        if (byte < 48 || byte > 55) throw new PortableBackupArchiveError("invalid_archive");
        result = result * 8 + byte - 48;
        if (!Number.isSafeInteger(result)) throw new PortableBackupArchiveError("invalid_archive");
    }
    return result;
}

function matches(bytes: Uint8Array, start: number, value: string): boolean {
    return [...value].every((character, index) => bytes[start + index] === character.charCodeAt(0));
}

function paddingSize(size: number): number {
    const remainder = size % BLOCK_SIZE;
    return remainder === 0 ? 0 : BLOCK_SIZE - remainder;
}

async function requireZeroPadding(archive: Blob, start: number): Promise<void> {
    const chunkSize = 1024 * 1024;
    for (let offset = start; offset < archive.size; offset += chunkSize) {
        const bytes = new Uint8Array(await archive.slice(offset, offset + chunkSize).arrayBuffer());
        if (bytes.some(byte => byte !== 0)) throw new PortableBackupArchiveError("invalid_archive");
    }
}
