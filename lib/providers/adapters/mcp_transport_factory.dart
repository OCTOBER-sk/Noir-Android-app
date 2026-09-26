// lib/providers/adapters/mcp_transport_factory.dart — the one place an MCP
// connection is actually opened (R2/B2).
//
// Everything above this file talks to [McpTransport], so the composition root
// takes a factory instead of a transport: a test injects a scripted, in-memory
// transport and never opens a socket, while production uses the dart:io HTTP
// client or a child process.
//
// The factory receives the bearer token as a ready-made header rather than
// reading the secret store itself, so there is exactly one place a token can
// reach a connection, and a transport that is handed a header already has it
// without knowing anything about secrets.
import '../../data/mcp_server_settings.dart';
import '../mcp/mcp_protocol.dart';
import '../mcp/mcp_transport.dart';

/// Builds the transport for one configured server.
///
/// [headers] carries the credentials the composition resolved from the secret
/// store; an unauthenticated server gets an empty map. A factory that cannot
/// connect throws [McpTransportException] rather than returning a transport that
/// fails later with a vaguer error.
///
/// An interface rather than a typedef so a test can implement it with a class and
/// so the production factory is a replaceable object in the composition root.
abstract interface class McpTransportFactory {
  McpTransport call(McpServerSettings server, Map<String, String> headers);
}

/// The production factory: dart:io HTTP, or a child process for stdio.
///
/// This is the only class in the MCP path that touches a socket or a process,
/// and it is replaceable, which is what keeps the test suite offline.
class IoMcpTransportFactory implements McpTransportFactory {
  const IoMcpTransportFactory({this.requestTimeout});

  /// Applied to the HTTP client. Null uses [IoMcpHttpClient]'s own default.
  final Duration? requestTimeout;

  @override
  McpTransport call(McpServerSettings server, Map<String, String> headers) {
    if (server.isStdio) {
      // The record holds an executable and no argument list, so the server is
      // launched exactly as written: an executable with arguments in the string
      // would be passed as one (wrong) program name.
      return McpStdioTransport(
        starter: IoMcpProcessStarter(executable: server.endpoint),
      );
    }
    final Uri? endpoint = server.httpEndpoint;
    if (endpoint == null) {
      throw const McpTransportException(
        kMcpTransportFailure,
        'MCP endpoint is not a URL: see the stored server record',
      );
    }
    return McpHttpTransport(
      endpoint: endpoint,
      headers: headers,
      client: requestTimeout == null
          ? null
          : IoMcpHttpClient(requestTimeout: requestTimeout!),
    );
  }
}
