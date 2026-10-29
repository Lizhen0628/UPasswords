import assert from "node:assert/strict";
import test from "node:test";
import {
    autofillConflictBlocks,
    buildAutofillConflictGateEntry,
    parseAutofillConflictGate,
} from "../dist/index.js";

const itemID = "123e4567-e89b-12d3-a456-426614174000";
const usernameID = "123e4567-e89b-12d3-a456-426614174001";
const passwordID = "123e4567-e89b-12d3-a456-426614174002";

function item(password = "secret") {
    return {
        id: itemID,
        title: "Work",
        symbol: null,
        host: "example.com",
        fields: [
            { id: usernameID, name: "Username", type: "login", value: "alice", autofill: "username" },
            { id: passwordID, name: "Password", type: "password", value: password, autofill: "current-password" },
        ],
    };
}

test("field-level gate blocks only the token whose stable field changed", () => {
    const entry = buildAutofillConflictGateEntry({
        itemID,
        currentItem: item("new-secret"),
        candidateItems: [item("old-secret")],
        hasUnreadableCandidate: false,
        hasDeleteCandidate: false,
        currentDeleted: false,
    });
    assert.deepEqual(entry, { itemID, fieldTokens: ["current-password"], wholeItem: false });

    const gate = parseAutofillConflictGate({
        version: 1,
        userId: "user",
        vaultId: "vault",
        checkedAt: 10,
        entries: [entry],
    });
    assert.equal(autofillConflictBlocks(gate, itemID, ["username"]), false);
    assert.equal(autofillConflictBlocks(gate, itemID, ["current-password"]), true);
});

test("unreadable, deleted, or unreliable identity conflicts fail closed for the item", () => {
    const deleted = buildAutofillConflictGateEntry({
        itemID,
        currentItem: item(),
        candidateItems: [item()],
        hasUnreadableCandidate: false,
        hasDeleteCandidate: true,
        currentDeleted: false,
    });
    assert.equal(deleted.wholeItem, true);

    const unreadable = buildAutofillConflictGateEntry({
        itemID,
        currentItem: item(),
        candidateItems: [null],
        hasUnreadableCandidate: true,
        hasDeleteCandidate: false,
        currentDeleted: false,
    });
    assert.equal(unreadable.wholeItem, true);

    const legacy = item();
    legacy.fields = legacy.fields.map(({ id, ...field }) => field);
    const unreliable = buildAutofillConflictGateEntry({
        itemID,
        currentItem: legacy,
        candidateItems: [item()],
        hasUnreadableCandidate: false,
        hasDeleteCandidate: false,
        currentDeleted: false,
    });
    assert.equal(unreliable.wholeItem, true);
});

test("persisted gate rejects malformed or duplicate entries", () => {
    assert.equal(parseAutofillConflictGate({
        version: 1, userId: "user", vaultId: "vault", checkedAt: 10,
        entries: [{ itemID, fieldTokens: ["current-password", "current-password"], wholeItem: false }],
    }), null);
    assert.equal(parseAutofillConflictGate({
        version: 1, userId: "user", vaultId: "vault", checkedAt: 10,
        entries: [{ itemID: "not-a-uuid", fieldTokens: [], wholeItem: false }],
    }), null);
});
