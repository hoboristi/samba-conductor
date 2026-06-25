import { Meteor } from 'meteor/meteor';
import { check, Match } from 'meteor/check';
import { getReadCredentials, getWriteCredentials } from '../auth/credentialStore';
import { listSshKeys, addSshKey, removeSshKey } from '../samba/sambaSshKeys';

const optionalString = Match.Maybe(String);

// Deferred import to avoid circular dependency with settingsMethods.js,
// matching the pattern already used in credentialStore.js -> getReadCredentials
async function getSyncCredentialsDeferred() {
  const { getSyncCredentials } = require('../settings/settingsMethods');
  return getSyncCredentials();
}

Meteor.methods({
  // READ — fallback to sync account. Admin view: any user's keys.
  'samba.sshKeys.list': async function listSshKeysMethod({ username }) {
    const credentials = await getReadCredentials({ userId: this.userId });
    check(username, String);
    return listSshKeys({ username, credentials });
  },

  // WRITE — requires active session. Admin action: manage any user's keys.
  'samba.sshKeys.add': async function addSshKeyMethod({ username, publicKey, label }) {
    const credentials = getWriteCredentials({ userId: this.userId });
    check(username, String);
    check(publicKey, String);
    check(label, optionalString);

    await addSshKey({ username, publicKey, label, credentials });
    return { success: true };
  },

  // WRITE — requires active session. Admin action: manage any user's keys.
  'samba.sshKeys.remove': async function removeSshKeyMethod({ username, keyData }) {
    const credentials = getWriteCredentials({ userId: this.userId });
    check(username, String);
    check(keyData, String);

    await removeSshKey({ username, keyData, credentials });
    return { success: true };
  },

  // Self-service READ — the logged-in user's own SSH keys
  'selfService.sshKeys.list': async function listOwnSshKeys() {
    const meteorUser = await Meteor.users.findOneAsync(this.userId);
    if (!meteorUser?.username) {
      throw new Meteor.Error('not-found', 'User not found');
    }

    const credentials = await getReadCredentials({ userId: this.userId });
    return listSshKeys({ username: meteorUser.username, credentials });
  },

  // Self-service WRITE — add a key to the logged-in user's own account.
  // Uses the sync account for the LDAP write, same as selfService.updateProfile,
  // since regular AD users may lack write permission on their own object.
  'selfService.sshKeys.add': async function addOwnSshKey({ publicKey, label }) {
    if (!this.userId) {
      throw new Meteor.Error('not-authorized', 'You must be logged in');
    }
    check(publicKey, String);
    check(label, optionalString);

    const meteorUser = await Meteor.users.findOneAsync(this.userId);
    if (!meteorUser?.username) {
      throw new Meteor.Error('not-found', 'User not found');
    }

    const syncCredentials = await getSyncCredentialsDeferred();
    if (!syncCredentials) {
      throw new Meteor.Error('sync-not-configured', 'Sync account is required to add SSH keys. Ask your admin to configure it in Settings.');
    }

    await addSshKey({ username: meteorUser.username, publicKey, label, credentials: syncCredentials });
    return { success: true };
  },

  // Self-service WRITE — remove a key from the logged-in user's own account.
  'selfService.sshKeys.remove': async function removeOwnSshKey({ keyData }) {
    if (!this.userId) {
      throw new Meteor.Error('not-authorized', 'You must be logged in');
    }
    check(keyData, String);

    const meteorUser = await Meteor.users.findOneAsync(this.userId);
    if (!meteorUser?.username) {
      throw new Meteor.Error('not-found', 'User not found');
    }

    const syncCredentials = await getSyncCredentialsDeferred();
    if (!syncCredentials) {
      throw new Meteor.Error('sync-not-configured', 'Sync account is required to remove SSH keys. Ask your admin to configure it in Settings.');
    }

    await removeSshKey({ username: meteorUser.username, keyData, credentials: syncCredentials });
    return { success: true };
  },
});
