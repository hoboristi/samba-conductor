import { getSambaConfig } from './sambaConfig';
import { createLdapClient, ldapBindWithCredentials, ldapSearch, ldapModify, ldapDisconnect } from './sambaLdap';
import ldap from 'ldapjs';
import { Meteor } from 'meteor/meteor';

const SUDOERS_OU_NAME = 'sudoers';

// Builds the DN of the sudoers container (ou=sudoers,<baseDn>)
function getSudoersBaseDn({ baseDn }) {
  return `ou=${SUDOERS_OU_NAME},${baseDn}`;
}

// Ensures the ou=sudoers container exists; creates it if missing
async function ensureSudoersOU({ client, baseDn }) {
  const sudoersBaseDn = getSudoersBaseDn({ baseDn });

  const existing = await ldapSearch({
    client,
    baseDn: sudoersBaseDn,
    filter: '(objectClass=organizationalUnit)',
    scope: 'base',
    attributes: ['ou'],
  }).catch(() => []);

  if (existing.length > 0) {
    return sudoersBaseDn;
  }

  await new Promise((resolve, reject) => {
    const entry = {
      objectClass: ['top', 'organizationalUnit'],
      ou: SUDOERS_OU_NAME,
      description: 'Sudo rules for domain-joined Linux hosts',
    };
    client.add(sudoersBaseDn, entry, (error) => {
      if (error) {
        reject(new Meteor.Error('samba.sudo.ou.create.failed', `Failed to create sudoers OU: ${error.message}`));
      } else {
        resolve();
      }
    });
  });

  return sudoersBaseDn;
}

// Normalizes a single LDAP attribute value into an array of strings
function toArray(value) {
  if (value === undefined || value === null) return [];
  return Array.isArray(value) ? value : [value];
}

// Lists all sudo rules stored under ou=sudoers
export async function listSudoRules({ credentials }) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });
    const sudoersBaseDn = await ensureSudoersOU({ client, baseDn });

    const entries = await ldapSearch({
      client,
      baseDn: sudoersBaseDn,
      filter: '(objectClass=sudoRole)',
      scope: 'one',
      attributes: [
        'cn',
        'sudoUser',
        'sudoHost',
        'sudoCommand',
        'sudoOption',
        'sudoRunAsUser',
        'sudoRunAsGroup',
        'description',
      ],
    });

    return entries.map((entry) => ({
      name: entry.cn,
      users: toArray(entry.sudoUser),
      hosts: toArray(entry.sudoHost).length ? toArray(entry.sudoHost) : ['ALL'],
      commands: toArray(entry.sudoCommand).length ? toArray(entry.sudoCommand) : ['ALL'],
      options: toArray(entry.sudoOption),
      runAsUser: entry.sudoRunAsUser || 'root',
      runAsGroup: entry.sudoRunAsGroup || '',
      description: entry.description || '',
      dn: entry.dn,
    }));
  } finally {
    ldapDisconnect({ client });
  }
}

// Creates a new sudo rule under ou=sudoers
export async function createSudoRule({
  name, users, hosts, commands, options, runAsUser, runAsGroup, description, credentials,
}) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });
    const sudoersBaseDn = await ensureSudoersOU({ client, baseDn });
    const dn = `cn=${name},${sudoersBaseDn}`;

    const entry = {
      objectClass: ['top', 'sudoRole'],
      cn: name,
      sudoUser: users,
      sudoHost: hosts && hosts.length ? hosts : ['ALL'],
      sudoCommand: commands && commands.length ? commands : ['ALL'],
    };

    if (options && options.length) entry.sudoOption = options;
    if (runAsUser) entry.sudoRunAsUser = runAsUser;
    if (runAsGroup) entry.sudoRunAsGroup = runAsGroup;
    if (description) entry.description = description;

    await new Promise((resolve, reject) => {
      client.add(dn, entry, (error) => {
        if (error) {
          reject(new Meteor.Error('samba.sudo.create.failed', `Failed to create sudo rule: ${error.message}`));
        } else {
          resolve();
        }
      });
    });
  } finally {
    ldapDisconnect({ client });
  }
}

// Updates an existing sudo rule's attributes
export async function updateSudoRule({ name, changes, credentials }) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });
    const sudoersBaseDn = getSudoersBaseDn({ baseDn });
    const dn = `cn=${name},${sudoersBaseDn}`;

    const attributeMap = {
      users: 'sudoUser',
      hosts: 'sudoHost',
      commands: 'sudoCommand',
      options: 'sudoOption',
      runAsUser: 'sudoRunAsUser',
      runAsGroup: 'sudoRunAsGroup',
      description: 'description',
    };

    const ldapChanges = [];
    Object.entries(changes).forEach(([key, value]) => {
      const attr = attributeMap[key];
      if (!attr || value === undefined) return;

      const values = Array.isArray(value) ? value : [value];
      ldapChanges.push(new ldap.Change({
        operation: values.length === 0 ? 'delete' : 'replace',
        modification: { type: attr, values: values.length ? values.map(String) : [] },
      }));
    });

    if (ldapChanges.length > 0) {
      await ldapModify({ client, dn, changes: ldapChanges });
    }
  } finally {
    ldapDisconnect({ client });
  }
}

// Deletes a sudo rule by name (cn)
export async function deleteSudoRule({ name, credentials }) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });
    const sudoersBaseDn = getSudoersBaseDn({ baseDn });
    const dn = `cn=${name},${sudoersBaseDn}`;

    await new Promise((resolve, reject) => {
      client.del(dn, (error) => {
        if (error) {
          reject(new Meteor.Error('samba.sudo.delete.failed', `Failed to delete sudo rule: ${error.message}`));
        } else {
          resolve();
        }
      });
    });
  } finally {
    ldapDisconnect({ client });
  }
}
