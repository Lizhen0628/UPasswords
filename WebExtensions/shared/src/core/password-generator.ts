export interface PasswordGeneratorOptions {
    length: number;
    uppercase: boolean;
    lowercase: boolean;
    digits: boolean;
    symbols: boolean;
}

const MIN_PASSWORD_LENGTH = 8;
const MAX_PASSWORD_LENGTH = 128;
const RANDOM_BUFFER_SIZE = 256;
const BYTE_RANGE = 256;
const CHARACTER_CLASSES = {
    uppercase: "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    lowercase: "abcdefghijklmnopqrstuvwxyz",
    digits: "0123456789",
    symbols: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
} as const;

/** Generate uniformly from selected characters, rejecting candidates missing any selected class. */
export function generatePassword(options: PasswordGeneratorOptions): string {
    if (!options || !Number.isInteger(options.length)
        || options.length < MIN_PASSWORD_LENGTH || options.length > MAX_PASSWORD_LENGTH) {
        throw new Error("bad_password_length");
    }
    const keys = Object.keys(CHARACTER_CLASSES) as (keyof typeof CHARACTER_CLASSES)[];
    if (keys.some((key) => typeof options[key] !== "boolean")) {
        throw new Error("bad_password_options");
    }
    const classes = keys.filter((key) => options[key]).map((key) => CHARACTER_CLASSES[key]);
    if (!classes.length) throw new Error("no_password_classes");
    const alphabet = classes.join("");
    // Discard the incomplete final bucket rather than introducing modulo bias.
    const limit = Math.floor(BYTE_RANGE / alphabet.length) * alphabet.length;
    const random = new Uint8Array(RANDOM_BUFFER_SIZE);
    let cursor = random.length;
    try {
        for (;;) {
            let candidate = "";
            while (candidate.length < options.length) {
                if (cursor === random.length) {
                    crypto.getRandomValues(random);
                    cursor = 0;
                }
                const byte = random[cursor++];
                if (byte < limit) candidate += alphabet[byte % alphabet.length];
            }
            if (classes.every((characters) => Array.from(candidate).some((char) => characters.includes(char)))) {
                console.debug("[upw] password generated", { length: options.length, classes: classes.length });
                return candidate;
            }
        }
    } finally {
        random.fill(0);
    }
}
