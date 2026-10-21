package com.ryanheise.just_audio;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.FutureTask;

/** Executable JVM fixtures using the same harness pattern as EqualizerDspTest. */
public final class ProgressiveLoadRetryTest {
    private static void check(boolean expected, String scheme, long length,
            Map<String, List<String>> headers, String context) {
        if (ProgressiveLoadRetry.isUnknownLengthHttp(scheme, length, headers) != expected) {
            throw new AssertionError(context);
        }
    }

    private static void incompleteChunkedBody() throws Exception {
        try (ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(2000);
            FutureTask<Void> origin = new FutureTask<>(() -> {
                try (Socket socket = server.accept()) {
                    socket.setSoTimeout(2000);
                    var request = new BufferedReader(new InputStreamReader(
                            socket.getInputStream(), StandardCharsets.US_ASCII));
                    while (!request.readLine().isEmpty()) { }
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\n"
                            + "Transfer-Encoding: chunked\r\n\r\n4\r\nsong\r\n")
                            .getBytes(StandardCharsets.US_ASCII));
                    // Close without the final zero-length chunk, as the proxy does on error.
                }
                return null;
            });
            new Thread(origin).start();
            HttpURLConnection connection = (HttpURLConnection) URI.create(
                    "http://127.0.0.1:" + server.getLocalPort() + "/song").toURL().openConnection();
            connection.setConnectTimeout(2000);
            connection.setReadTimeout(2000);
            int received = 0;
            try (var body = connection.getInputStream()) {
                while (body.read() != -1) received++;
                throw new AssertionError("incomplete chunked body must throw IOException");
            } catch (IOException expected) {
                if (received != 4) throw new AssertionError("must receive the partial song first");
                check(true, connection.getURL().getProtocol(), -1, connection.getHeaderFields(),
                        "incomplete chunked IOException must select the fatal policy");
            } finally {
                connection.disconnect();
                origin.get();
            }
        }
    }

    public static void main(String[] args) throws Exception {
        Map<String, List<String>> chunked = Map.of("transfer-encoding", List.of("chunked"));
        check(true, "http", -1, chunked, "chunked proxy must reach Dart recovery");
        check(true, "https", -1, Map.of("Content-Type", List.of("audio/ogg")),
                "unknown-length direct offset must reach Dart recovery");
        check(false, "http", -1, Map.of("content-range", List.of("Bytes 0-1/500")),
                "Content-Range units are case-insensitive");
        check(false, "https", -1, Map.of("cOnTeNt-LeNgTh", List.of("1122746")),
                "sized response retains native retry");
        check(false, "https", -1, Map.of("Content-Length", List.of("0")),
                "empty sized response retains default error policy");
        check(false, "https", -1, Map.of("Content-Range", List.of("bytes 100-199/500")),
                "ranged response retains native retry");
        check(false, "https", -1, Map.of("Content-Range", List.of("bytes 100-199/*")),
                "a range has a known body length even without a total");
        check(false, "https", 100, chunked, "bounded data request retains native retry");
        check(false, "file", -1, Collections.emptyMap(), "local errors retain default policy");
        check(false, "https", -1, Collections.emptyMap(), "connection errors retain native retry");
        check(true, "https", -1, Map.of("Content-Length", List.of("-1")),
                "negative length is unknown");
        check(true, "https", -1, Map.of("Content-Length", List.of("invalid")),
                "invalid length is unknown");
        incompleteChunkedBody();
        System.out.println("ProgressiveLoadRetryTest: 13 fixtures passed");
    }
}
