String rulesJson({bool available = true, bool management = true, bool policy = true}) =>
    '{"version":1,"rules":{"available":$available,"managementAvailable":$management,"disconnectPolicy":$policy}}';
final rulesAvailableJson = rulesJson();
final rulesUnavailableJson = rulesJson(available: false);
final rulesManagementOnlyJson = rulesJson(available: false, management: true);
