import React, { useState, useEffect } from 'react';
import { Meteor } from 'meteor/meteor';
import { useAlert } from 'meteor/quave:alert-react-tailwind';
import { Button } from '../components/Button';
import { DataTable } from '../components/DataTable';
import { ConfirmModal } from '../components/ConfirmModal';
import { Loading } from '../components/Loading';

const BLANK_FORM = {
  name: '',
  users: '',
  hosts: 'ALL',
  commands: 'ALL',
  options: '',
  runAsUser: 'root',
  runAsGroup: '',
  description: '',
};

// Splits a comma-separated string into a trimmed, non-empty array
function parseList({ value }) {
  return value
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

// Joins an array of strings into a comma-separated display string
function joinList({ values }) {
  return (values || []).join(', ');
}

export function SudoRules() {
  const { openAlert } = useAlert();

  const [rules, setRules] = useState([]);
  const [loading, setLoading] = useState(true);

  const [showForm, setShowForm] = useState(false);
  const [editingName, setEditingName] = useState(null);
  const [form, setForm] = useState(BLANK_FORM);
  const [submitting, setSubmitting] = useState(false);

  const [deleteTarget, setDeleteTarget] = useState(null);

  async function fetchRules() {
    try {
      const result = await Meteor.callAsync('samba.sudo.list');
      setRules(result);
    } catch (error) {
      openAlert(error.reason || 'Failed to load sudo rules');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    fetchRules();
  }, []);

  function handleChange({ field, value }) {
    setForm((prev) => ({ ...prev, [field]: value }));
  }

  function openCreateForm() {
    setForm(BLANK_FORM);
    setEditingName(null);
    setShowForm(true);
  }

  function openEditForm({ rule }) {
    setForm({
      name: rule.name,
      users: joinList({ values: rule.users }),
      hosts: joinList({ values: rule.hosts }),
      commands: joinList({ values: rule.commands }),
      options: joinList({ values: rule.options }),
      runAsUser: rule.runAsUser || 'root',
      runAsGroup: rule.runAsGroup || '',
      description: rule.description || '',
    });
    setEditingName(rule.name);
    setShowForm(true);
  }

  async function handleSubmit(event) {
    event.preventDefault();

    if (!form.name.trim()) {
      openAlert('Rule name is required');
      return;
    }
    if (!form.users.trim()) {
      openAlert('At least one user or group is required');
      return;
    }

    setSubmitting(true);

    try {
      if (editingName) {
        await Meteor.callAsync('samba.sudo.update', {
          name: editingName,
          changes: {
            users: parseList({ value: form.users }),
            hosts: parseList({ value: form.hosts }),
            commands: parseList({ value: form.commands }),
            options: parseList({ value: form.options }),
            runAsUser: form.runAsUser.trim() || 'root',
            runAsGroup: form.runAsGroup.trim(),
            description: form.description.trim(),
          },
        });
        openAlert('Sudo rule updated successfully');
      } else {
        await Meteor.callAsync('samba.sudo.create', {
          name: form.name.trim(),
          users: parseList({ value: form.users }),
          hosts: parseList({ value: form.hosts }),
          commands: parseList({ value: form.commands }),
          options: parseList({ value: form.options }),
          runAsUser: form.runAsUser.trim() || 'root',
          runAsGroup: form.runAsGroup.trim() || undefined,
          description: form.description.trim() || undefined,
        });
        openAlert('Sudo rule created successfully');
      }

      setShowForm(false);
      setEditingName(null);
      await fetchRules();
    } catch (error) {
      openAlert(error.reason || 'Failed to save sudo rule');
    } finally {
      setSubmitting(false);
    }
  }

  async function handleDelete() {
    if (!deleteTarget) return;

    try {
      await Meteor.callAsync('samba.sudo.delete', { name: deleteTarget });
      setDeleteTarget(null);
      await fetchRules();
    } catch (error) {
      openAlert(error.reason || 'Failed to delete sudo rule');
    }
  }

  const columns = [
    {
      header: 'Name',
      accessor: 'name',
      render(row) {
        return (
          <div>
            <span className="font-medium text-fg">{row.name}</span>
            {row.description && (
              <p className="text-xs text-fg-muted">{row.description}</p>
            )}
          </div>
        );
      },
    },
    {
      header: 'Users / Groups',
      accessor: 'users',
      render(row) {
        return (
          <div className="flex flex-wrap gap-1">
            {row.users.map((user) => (
              <span
                key={user}
                className="inline-flex items-center rounded-full bg-surface-input px-2 py-0.5 text-xs text-fg-secondary"
              >
                {user}
              </span>
            ))}
          </div>
        );
      },
    },
    {
      header: 'Hosts',
      accessor: 'hosts',
      render(row) {
        return <span className="text-fg-secondary">{row.hosts.join(', ')}</span>;
      },
    },
    {
      header: 'Commands',
      accessor: 'commands',
      render(row) {
        return (
          <span className="block max-w-xs text-wrap break-words text-fg-secondary">
            {row.commands.join(', ')}
          </span>
        );
      },
    },
    {
      header: 'Actions',
      render(row) {
        return (
          <div className="flex gap-2">
            <button
              onClick={(e) => {
                e.stopPropagation();
                openEditForm({ rule: row });
              }}
              data-e2e="sudo-rules-link-edit"
              className="text-xs text-accent hover:text-accent-hover"
            >
              Edit
            </button>
            <button
              onClick={(e) => {
                e.stopPropagation();
                setDeleteTarget(row.name);
              }}
              data-e2e="sudo-rules-btn-delete"
              className="text-xs text-red-400 hover:text-red-300"
            >
              Delete
            </button>
          </div>
        );
      },
    },
  ];

  if (loading) {
    return <Loading />;
  }

  return (
    <div>
      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-fg">Sudo Rules</h1>
          <p className="mt-1 text-sm text-fg-secondary">
            Manage sudo access rules stored in Active Directory (ou=sudoers)
          </p>
        </div>
        <Button primary onClick={openCreateForm} data-e2e="sudo-rules-btn-new">
          New Rule
        </Button>
      </div>

      {showForm && (
        <form onSubmit={handleSubmit} className="mb-6 w-full max-w-2xl">
          <div className="rounded-xl bg-surface-card border border-border p-5 space-y-4">
            <h3 className="text-sm font-semibold text-fg">
              {editingName ? `Edit Rule: ${editingName}` : 'New Sudo Rule'}
            </h3>

            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              <div className="sm:col-span-2">
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Rule Name (cn) *
                </label>
                <input
                  type="text"
                  value={form.name}
                  onChange={(e) => handleChange({ field: 'name', value: e.target.value })}
                  disabled={!!editingName}
                  placeholder="devops-restart"
                  data-e2e="sudo-rules-input-name"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent disabled:opacity-50"
                />
              </div>

              <div className="sm:col-span-2">
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Users / Groups (sudoUser) *
                </label>
                <input
                  type="text"
                  value={form.users}
                  onChange={(e) => handleChange({ field: 'users', value: e.target.value })}
                  placeholder="alice, %devops, ALL"
                  data-e2e="sudo-rules-input-users"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
                <p className="mt-0.5 text-xs text-fg-muted">
                  Comma-separated. Prefix groups with %. Use ALL for everyone.
                </p>
              </div>

              <div>
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Hosts (sudoHost)
                </label>
                <input
                  type="text"
                  value={form.hosts}
                  onChange={(e) => handleChange({ field: 'hosts', value: e.target.value })}
                  placeholder="ALL"
                  data-e2e="sudo-rules-input-hosts"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Run As User
                </label>
                <input
                  type="text"
                  value={form.runAsUser}
                  onChange={(e) => handleChange({ field: 'runAsUser', value: e.target.value })}
                  placeholder="root"
                  data-e2e="sudo-rules-input-runas-user"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
              </div>

              <div className="sm:col-span-2">
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Commands (sudoCommand)
                </label>
                <input
                  type="text"
                  value={form.commands}
                  onChange={(e) => handleChange({ field: 'commands', value: e.target.value })}
                  placeholder="/usr/bin/systemctl restart *, ALL"
                  data-e2e="sudo-rules-input-commands"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
                <p className="mt-0.5 text-xs text-fg-muted">
                  Comma-separated. Use ALL for all commands. Prefix with ! to deny.
                </p>
              </div>

              <div>
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Options (sudoOption)
                </label>
                <input
                  type="text"
                  value={form.options}
                  onChange={(e) => handleChange({ field: 'options', value: e.target.value })}
                  placeholder="!authenticate, NOPASSWD"
                  data-e2e="sudo-rules-input-options"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
              </div>

              <div>
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Run As Group (optional)
                </label>
                <input
                  type="text"
                  value={form.runAsGroup}
                  onChange={(e) => handleChange({ field: 'runAsGroup', value: e.target.value })}
                  placeholder="wheel"
                  data-e2e="sudo-rules-input-runas-group"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
              </div>

              <div className="sm:col-span-2">
                <label className="block text-xs font-medium text-fg-secondary mb-1">
                  Description
                </label>
                <input
                  type="text"
                  value={form.description}
                  onChange={(e) => handleChange({ field: 'description', value: e.target.value })}
                  placeholder="Allow DevOps team to restart services"
                  data-e2e="sudo-rules-input-description"
                  className="w-full rounded-lg border border-border bg-surface-input px-3 py-2 text-sm text-fg placeholder-fg-muted focus:border-accent focus:outline-none focus:ring-1 focus:ring-accent"
                />
              </div>
            </div>

            <div className="flex gap-3 pt-2">
              <Button primary type="submit" disabled={submitting} data-e2e="sudo-rules-btn-submit">
                {submitting ? 'Saving...' : editingName ? 'Save Changes' : 'Create Rule'}
              </Button>
              <Button
                secondary
                type="button"
                onClick={() => { setShowForm(false); setEditingName(null); }}
                data-e2e="sudo-rules-btn-cancel-form"
              >
                Cancel
              </Button>
            </div>
          </div>
        </form>
      )}

      <DataTable
        columns={columns}
        data={rules}
        searchPlaceholder="Search sudo rules..."
        data-e2e="sudo-rules-table"
      />

      <ConfirmModal
        isOpen={!!deleteTarget}
        title="Delete Sudo Rule"
        message={`Are you sure you want to delete "${deleteTarget}"? This action cannot be undone.`}
        confirmLabel="Delete"
        danger
        onConfirm={handleDelete}
        onCancel={() => setDeleteTarget(null)}
        data-e2e="sudo-rules-delete"
      />
    </div>
  );
}
