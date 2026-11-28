import 'dart:convert';

/// Only fields bound to the signed action may describe a lasting rule.
Map<String, dynamic>? checkedAssignmentRule(
  List a,
  Map<String, dynamic>? summary,
) {
  if (a.length < 16) throw const FormatException();
  final v = a[1];
  if (v != 3 && v != 4) {
    if (summary?['rule'] != null) throw const FormatException('Unsigned rule');
    return null;
  }
  final raw = a.last;
  if (raw is! String) throw const FormatException();
  final d = jsonDecode(raw);
  final supplied = summary?['rule'];
  if (d is! List) throw const FormatException();
  if (d.length == 2 && d[0] == 'none' && d[1] is String) {
    if (summary != null &&
        (supplied is! Map ||
            supplied['status'] != 'unavailable' ||
            supplied['reason'] != d[1])) {
      throw const FormatException();
    }
    return {'status': 'unavailable', 'reason': d[1]};
  }
  bool safe(dynamic x) =>
      x is String &&
      x.isNotEmpty &&
      x.length <= 256 &&
      !RegExp(
        r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2066-\u2069\u061c\ufeff]',
      ).hasMatch(x);
  if (d.length != 8 ||
      d[0] != 'save' ||
      !['sms_number', 'email_address'].contains(d[1]) ||
      !safe(d[2]) ||
      (d[3] != null && !safe(d[3])) ||
      d[4] != a[6] ||
      !safe(d[5]) ||
      (v == 4 && d[5] != a[18]) ||
      ((d[6] == null) == (d[7] == null)) ||
      (d[6] != null && !safe(d[6])) ||
      (d[7] != null &&
          (d[7] is! String || !RegExp(r'^v1:[a-f0-9]{64}$').hasMatch(d[7])))) {
    throw const FormatException();
  }
  final basis = d[6] == null ? 'template' : 'phrase';
  if (summary != null &&
      (supplied is! Map ||
          !['will_save', 'already_saved_paused'].contains(supplied['status']) ||
          supplied['senderKind'] != d[1] ||
          supplied['sender'] != d[2] ||
          supplied['phrase'] != d[6] ||
          supplied['basis'] != basis ||
          supplied['futureRecipients'] != a[13] ||
          supplied['futureAutomations'] != a[14] ||
          summary['serviceId'] != d[5])) {
    throw const FormatException();
  }
  if (supplied is Map &&
      supplied['status'] == 'already_saved_paused' &&
      (!safe(supplied['ruleId']) ||
          supplied['resumeRequiresSignedAction'] != true)) {
    throw const FormatException();
  }
  return {
    'status': supplied is Map ? supplied['status'] : 'will_save',
    if (supplied is Map && supplied['status'] == 'already_saved_paused') ...{
      'ruleId': supplied['ruleId'],
      'resumeRequiresSignedAction': true,
    },
    'senderKind': d[1],
    'sender': d[2],
    'connectorId': d[4],
    'addressScope': d[3] == null ? 'any-address-on-connector' : 'receiving-address',
    'phrase': d[6],
    'basis': basis,
    'futureRecipients': a[13],
    'futureAutomations': a[14],
  };
}

/// A will_save rule is shown and confirmable only with a verified signed
/// connector and address scope. Missing or unknown values never default broad.
bool assignmentRuleScopeVerified(Map<String, dynamic> r) =>
    r['status'] != 'will_save' ||
    (r['connectorId'] is String &&
        (r['connectorId'] as String).isNotEmpty &&
        ['receiving-address', 'any-address-on-connector'].contains(
          r['addressScope'],
        ));

String assignmentRuleDisclosure(Map<String, dynamic> r) =>
    r['status'] == 'will_save' && !assignmentRuleScopeVerified(r)
    ? 'The address scope of this rule could not be verified. Nothing will be saved.'
    : r['status'] == 'will_save'
    ? 'Future matching codes from ${r['sender']} on connector ${r['connectorId']} will go to this account. ${r['addressScope'] == 'receiving-address' ? 'Only the original receiving address is covered.' : 'All receiving addresses on this connector are covered.'} Match: ${r['basis'] == 'template' ? 'message template' : 'phrase "${r['phrase']}"'}. Future matching codes will be shared with ${r['futureRecipients']} recipients / ${r['futureAutomations']} automations.'
    : r['status'] == 'already_saved_paused'
    ? 'The matching rule is paused. Assigning this code will not resume it. Resume requires a separate confirmation.'
    : 'No future rule can be saved for this message.';
