// A link that is not a loopback: one origin in front of one or two servers, where every
// request waits `latencyMs` before it is sent on and every response is paced to `mbps`.
// Bodies pass through as they were sent (gzip stays gzip, a stream stays a stream), and so does
// the Host header, so a redirect the server writes points back at the link.
//
//   const origin = await slowLink({ port: 4181, latencyMs: 60, mbps: 20, upstream: () => RAILS })
//
// `upstream(path)` answers with the URL of the server that path belongs to.
import { createServer, request as httpRequest } from "node:http";

export function slowLink({ port, latencyMs, mbps, upstream }) {
  const bytesPerMs = mbps * 1e6 / 8 / 1000;
  const server = createServer((request, response) => {
    const target = upstream(request.url);
    setTimeout(() => {
      const forward = httpRequest({ host: target.hostname, port: target.port, path: request.url, method: request.method,
        headers: request.headers }, (answer) => {
        response.writeHead(answer.statusCode, answer.headers);
        // Each chunk leaves when the link would have carried it, one after another: a queue,
        // so the end can never overtake the last chunk.
        let due = performance.now();
        let sent = Promise.resolve();
        const at = (time) => new Promise((resolve) => setTimeout(resolve, Math.max(0, time - performance.now())));
        answer.on("data", (chunk) => {
          due = Math.max(due, performance.now()) + chunk.length / bytesPerMs;
          const leaves = due;
          sent = sent.then(() => at(leaves)).then(() => response.write(chunk));
        });
        answer.on("end", () => { sent = sent.then(() => response.end()); });
        answer.on("error", () => response.destroy());
      });
      forward.on("error", () => response.destroy());
      response.on("close", () => forward.destroy());
      request.pipe(forward);
    }, latencyMs);
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(`http://127.0.0.1:${port}`)));
}
