// The catalog under test is the one lib/data ships, not a test-only variant.
import 'package:noir_android_app/data/data.dart';

SchemaCatalog buildNoirCatalog({
  SecretStore? secrets,
  DateTime Function()? clock,
}) => NoirSchema.catalog(secrets: secrets, clock: clock);
