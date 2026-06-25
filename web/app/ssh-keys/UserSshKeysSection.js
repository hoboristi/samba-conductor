import React, { useState, useEffect } from 'react';
import { Meteor } from 'meteor/meteor';
import { Button } from '../components/Button';

// Admin-side SSH key manager for a given AD username.
// Mirrors the UserGroupsSection pattern used in UserForm.js.
export function UserSshKeysSection({ username, openAlert }) {
  const [keys, setKeys] = useState([]);
  const [loading, setLoading] = useState(true);
  const [newKey, setNewKey] = useState('');
  const [newLabel, setNewLabel] = useState('');
  const [adding, setAdding] = useState(false);

  async function fetchKeys() {
    try {
      const result = await Meteor.callAsync('samba.sshKeys.list', { username });
      setKeys(result);
    } catch (error) {
      openAlert(error.reason || 'Failed to load SSH keys');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    fetchKeys();
  }, [username]);

  async function handleAdd() {
    if (!newKey.trim()) {
      openAlert('Please paste a public key');
      return;
    }

    setAdding(true);
    try {
      await Meteor.callAsync('samba.sshKeys.add', {
        username,
        publicKey: newKey.trim(),
        label: newLabel.trim() || undefined,
      });
      setNewKey('');
      setNewLabel('');
      await fetchKeys();
      openAlert('SSH key added successfully');
    } catch (error) {
      openAlert(error.reason || 'Failed to add SSH key');
    } finally {
      setAdding(false);
    }
  }

  async function handleRemove({ keyData }) {
    try {
      await Meteor.callAsync('samba.sshKeys.remove', { username, keyData });
      setKeys((prev) => prev.filter((k) => k.keyData !== keyData));
      openAlert('SSH key removed');
    } catch (error) {
      openAlert(error.reason || 'Failed to remove SSH key');
    }
  }

  return (
    <div className="mt-8 w-full max-w-2xl">
      <div className="rounded-xl bg-surface-card border border-border p-5">
        <h3 className="text-sm font-semibold text-fg mb-4">
          SSH Public Keys ({keys.length})
        </h3>

        {/* Add key form */}
        <div className="space-y-2 mb-4">
          <textarea
            value={newKey}
            onChange={(e) => setNewKey(e.target.value)}
            placeholder="ssh-ed25519 AAAA... user@host"
            rows={3}
            disabled={adding}
            data-e2e="user-ssh-keys-textarea-key"
            className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-xs font-mono text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent disabled:opacity-50"
          />
          <div className="flex gap-2">
            <input
              type="text"
              value={newLabel}
              onChange={(e) => setNewLabel(e.target.value)}
              placeholder="Label (optional, e.g. work-laptop)"
              disabled={adding}
              data-e2e="user-ssh-keys-input-label"
              className="flex-1 rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent disabled:opacity-50"
            />
            <Button
              secondary
              type="button"
              onClick={handleAdd}
              disabled={adding || !newKey.trim()}
              data-e2e="user-ssh-keys-btn-add"
            >
              {adding ? 'Adding...' : 'Add Key'}
            </Button>
          </div>
        </div>

        {/* Key list */}
        {loading ? (
          <p className="text-sm text-fg-muted">Loading...</p>
        ) : (
          <div className="rounded-lg border border-border divide-y divide-border">
            {keys.length === 0 ? (
              <p className="p-4 text-sm text-fg-muted">No SSH keys registered</p>
            ) : (
              keys.map((key) => (
                <div key={key.keyData} className="flex items-center justify-between px-4 py-2.5 gap-3">
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="text-sm font-medium text-fg-secondary">{key.label}</span>
                      <span className="text-xs text-fg-muted">{key.keyType}</span>
                    </div>
                    <code className="text-xs text-fg-muted break-all">
                      {key.keyData.length > 50 ? `${key.keyData.slice(0, 50)}…` : key.keyData}
                    </code>
                  </div>
                  <button
                    type="button"
                    onClick={() => handleRemove({ keyData: key.keyData })}
                    data-e2e="user-ssh-keys-btn-remove"
                    className="text-xs text-red-400 hover:text-red-300 shrink-0"
                  >
                    Remove
                  </button>
                </div>
              ))
            )}
          </div>
        )}
      </div>
    </div>
  );
}
