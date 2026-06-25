import { Meteor } from 'meteor/meteor';
import { check, Match } from 'meteor/check';
import { getReadCredentials, getWriteCredentials } from '../auth/credentialStore';
import {
  listSudoRules,
  createSudoRule,
  updateSudoRule,
  deleteSudoRule,
} from '../samba/sambaSudo';

const optionalString = Match.Maybe(String);
const optionalStringArray = Match.Maybe([String]);

Meteor.methods({
  // READ — fallback to sync account
  'samba.sudo.list': async function listSudoRulesMethod() {
    const credentials = await getReadCredentials({ userId: this.userId });
    return listSudoRules({ credentials });
  },

  // WRITE — requires active session
  'samba.sudo.create': async function createSudoRuleMethod({
    name, users, hosts, commands, options, runAsUser, runAsGroup, description,
  }) {
    const credentials = getWriteCredentials({ userId: this.userId });

    check(name, String);
    check(users, [String]);
    check(hosts, optionalStringArray);
    check(commands, optionalStringArray);
    check(options, optionalStringArray);
    check(runAsUser, optionalString);
    check(runAsGroup, optionalString);
    check(description, optionalString);

    if (!name.trim()) {
      throw new Meteor.Error('validation', 'Rule name is required');
    }
    if (!users.length) {
      throw new Meteor.Error('validation', 'At least one user or group is required');
    }

    await createSudoRule({
      name: name.trim(), users, hosts, commands, options, runAsUser, runAsGroup, description, credentials,
    });
    return { success: true };
  },

  // WRITE — requires active session
  'samba.sudo.update': async function updateSudoRuleMethod({ name, changes }) {
    const credentials = getWriteCredentials({ userId: this.userId });

    check(name, String);
    check(changes, Object);

    await updateSudoRule({ name, changes, credentials });
    return { success: true };
  },

  // WRITE — requires active session
  'samba.sudo.delete': async function deleteSudoRuleMethod({ name }) {
    const credentials = getWriteCredentials({ userId: this.userId });
    check(name, String);

    await deleteSudoRule({ name, credentials });
    return { success: true };
  },
});
