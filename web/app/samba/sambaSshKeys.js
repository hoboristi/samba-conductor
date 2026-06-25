import { getSambaConfig } from './sambaConfig';
import { createLdapClient, ldapBindWithCredentials, ldapSearch, ldapModify, ldapDisconnect } from './sambaLdap';
import ldap from 'ldapjs';
import { Meteor } from 'meteor/meteor';

// Prefix used to tag SSH public keys inside altSecurityIdentities,
// matching the convention SSSD's ldap_user_ssh_public_key feature expects
// when pointed at this attribute.
const SSH_KEY_PREFIX = 'SSHKey:';

const VALID_KEY_PREFIXES = [
  'ssh-rsa ',
  'ssh-ed25519 ',
  'ecdsa-sha2-nistp256 ',
  'ecdsa-sha2-nistp384 ',
  'ecdsa-sha2-nistp521 ',
  'sk-ssh-ed25519@openssh.com ',
  'sk-ecdsa-sha2-nistp256@openssh.com ',
];

// Validates basic OpenSSH public key format and returns the trimmed key
function validatePublicKey({ publicKey }) {
  const trimmed = String(publicKey || '').trim();

  if (!VALID_KEY_PREFIXES.some((prefix) => trimmed.startsWith(prefix))) {
    throw new Meteor.Error(
      'samba.sshKeys.invalidFormat',
      `Unsupported SSH key type. Expected one of: ${VALID_KEY_PREFIXES.map((p) => p.trim()).join(', ')}`
    );
  }

  if (trimmed.split(/\s+/).length < 2) {
    throw new Meteor.Error('samba.sshKeys.invalidFormat', 'Invalid SSH public key format');
  }

  return trimmed;
}

// Finds a user's DN and current altSecurityIdentities values
async function getUserSshState({ client, baseDn, username }) {
  const entries = await ldapSearch({
    client,
    baseDn,
    filter: `(&(objectClass=user)(sAMAccountName=${username}))`,
    attributes: ['altSecurityIdentities'],
  });

  if (entries.length === 0) {
    throw new Meteor.Error('samba.sshKeys.userNotFound', `User '${username}' was not found`);
  }

  const entry = entries[0];
  const raw = Array.isArray(entry.altSecurityIdentities)
    ? entry.altSecurityIdentities
    : entry.altSecurityIdentities
      ? [entry.altSecurityIdentities]
      : [];

  return { dn: entry.dn, values: raw };
}

// Lists SSH public keys for a given AD user
export async function listSshKeys({ username, credentials }) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });
    const { values } = await getUserSshState({ client, baseDn, username });

    return values
      .filter((value) => value.startsWith(SSH_KEY_PREFIX))
      .map((value) => {
        const keyStr = value.slice(SSH_KEY_PREFIX.length).trim();
        const [keyType, keyData, ...commentParts] = keyStr.split(/\s+/);
        return {
          keyType: keyType || '',
          keyData: keyData || '',
          label: commentParts.join(' ') || '(no label)',
          fullKey: keyStr,
        };
      });
  } finally {
    ldapDisconnect({ client });
  }
}

// Adds a new SSH public key to a user's altSecurityIdentities attribute
export async function addSshKey({ username, publicKey, label, credentials }) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });

    let cleanKey = validatePublicKey({ publicKey });

    if (label && label.trim()) {
      const [keyType, keyData] = cleanKey.split(/\s+/);
      cleanKey = `${keyType} ${keyData} ${label.trim().replace(/\s+/g, '_')}`;
    }

    const { dn, values } = await getUserSshState({ client, baseDn, username });
    const newKeyData = cleanKey.split(/\s+/)[1];

    const isDuplicate = values
      .filter((value) => value.startsWith(SSH_KEY_PREFIX))
      .some((value) => value.slice(SSH_KEY_PREFIX.length).trim().split(/\s+/)[1] === newKeyData);

    if (isDuplicate) {
      throw new Meteor.Error('samba.sshKeys.duplicate', 'This SSH public key is already registered for this user');
    }

    await ldapModify({
      client,
      dn,
      changes: [
        new ldap.Change({
          operation: 'add',
          modification: { type: 'altSecurityIdentities', values: [`${SSH_KEY_PREFIX}${cleanKey}`] },
        }),
      ],
    });
  } finally {
    ldapDisconnect({ client });
  }
}

// Removes an SSH public key from a user, identified by its base64 key data
export async function removeSshKey({ username, keyData, credentials }) {
  const client = createLdapClient();
  const { baseDn } = getSambaConfig();

  try {
    await ldapBindWithCredentials({ client, credentials });
    const { dn, values } = await getUserSshState({ client, baseDn, username });

    const toRemove = values
      .filter((value) => value.startsWith(SSH_KEY_PREFIX))
      .filter((value) => value.slice(SSH_KEY_PREFIX.length).trim().split(/\s+/)[1] === keyData);

    if (toRemove.length === 0) {
      throw new Meteor.Error('samba.sshKeys.notFound', 'SSH key not found for this user');
    }

    await ldapModify({
      client,
      dn,
      changes: [
        new ldap.Change({
          operation: 'delete',
          modification: { type: 'altSecurityIdentities', values: toRemove },
        }),
      ],
    });
  } finally {
    ldapDisconnect({ client });
  }
}
