// Lichtblick と Foxglove が使うのと同じクライアントと復号器で、pocketsensor のサーバーを確かめる。
//
//   node check.mjs                      擬似デバイス（pocketsensor-sim）を起動して確かめる
//   node check.mjs ws://host:8765 [秒]  動いている端末を確かめる。秒は受信を続ける長さ（既定は 3.5）
//
// 終了コードは、問題が無ければ 0、あれば 1。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { FoxgloveClient } from "@foxglove/ws-protocol";
import { parse as parseDefinition } from "@foxglove/rosmsg";
import { MessageReader, MessageWriter } from "@foxglove/rosmsg2-serialization";
import WebSocket from "ws";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SIM = path.resolve(HERE, "../../ios/PocketSensorKit/.build/debug/pocketsensor-sim");
// 1 Hz のチャンネル（電池、診断）が少なくとも 1 件届く長さ。
const LISTEN_MS = Math.round(Number(process.argv[3] ?? "3.5") * 1000);
// 実機の GNSS は、最初の測位までの時間が空の見え方で変わり、屋内では届かないこともある。届かなくても問題にしない。
const MAY_BE_SILENT = ["/gnss/fix", "/gnss/time_reference"];
const NEW_COLOR_RATE = 7;

function startSim() {
  return new Promise((resolve, reject) => {
    const proc = spawn(SIM, ["--port", "0", "--no-bonjour", "--duration", "60", "--quiet"], {
      stdio: ["ignore", "pipe", "inherit"],
    });
    const timer = setTimeout(() => reject(new Error("pocketsensor-sim did not print READY within 10 s")), 10000);
    proc.on("error", (err) => reject(new Error(`cannot start ${SIM}: ${err.message}. Run "mise run build:sim" first.`)));
    let buffered = "";
    proc.stdout.on("data", (chunk) => {
      buffered += chunk.toString();
      const match = buffered.match(/READY port=(\d+)/);
      if (match) {
        clearTimeout(timer);
        resolve({ proc, url: `ws://127.0.0.1:${match[1]}` });
      }
    });
  });
}

function check(url) {
  return new Promise((resolve) => {
    const client = new FoxgloveClient({ ws: new WebSocket(url, [FoxgloveClient.SUPPORTED_SUBPROTOCOL]) });
    const readers = new Map(); // subscriptionId -> { topic, reader }
    const topics = new Map(); // topic -> { schema, count }
    const problems = [];
    const notes = [];
    const seen = { serverInfo: null, clock: null, parameters: null, setResult: null };

    client.on("error", (err) => problems.push(`client error: ${err?.message ?? err}`));
    client.on("status", (status) => problems.push(`server status level=${status.level}: ${status.message}`));
    client.on("serverInfo", (info) => {
      seen.serverInfo = info;
    });

    client.on("advertise", (channels) => {
      for (const channel of channels) {
        topics.set(channel.topic, { schema: channel.schemaName, count: 0 });
        if (channel.encoding !== "cdr" || channel.schemaEncoding !== "ros2msg") {
          problems.push(`${channel.topic}: unexpected encoding ${channel.encoding}/${channel.schemaEncoding}`);
          continue;
        }
        try {
          const reader = new MessageReader(parseDefinition(channel.schema, { ros2: true }));
          readers.set(client.subscribe(channel.id), { topic: channel.topic, reader });
        } catch (err) {
          problems.push(`${channel.topic}: schema does not parse: ${err.message}`);
        }
      }
    });

    client.on("message", ({ subscriptionId, timestamp, data }) => {
      const entry = readers.get(subscriptionId);
      if (!entry) {
        problems.push(`message for unknown subscription ${subscriptionId}`);
        return;
      }
      const stat = topics.get(entry.topic);
      try {
        const message = entry.reader.readMessage(data);
        stat.count += 1;
        const stamp = message.header?.stamp;
        if (stamp && stat.count === 1) {
          const stampNs = BigInt(stamp.sec) * 1000000000n + BigInt(stamp.nsec ?? stamp.nanosec);
          if (stampNs !== timestamp) {
            problems.push(`${entry.topic}: header.stamp ${stampNs} differs from the wire timestamp ${timestamp}`);
          }
        }
      } catch (err) {
        if (stat.count === 0) {
          problems.push(`${entry.topic}: decode failed: ${err.message}`);
        }
        stat.count = -1;
      }
    });

    client.on("advertiseServices", (services) => {
      const clock = services.find((service) => service.name.endsWith("/clock_sync"));
      if (!clock) {
        problems.push("clock_sync is not advertised");
        return;
      }
      try {
        const writer = new MessageWriter(parseDefinition(clock.request?.schema ?? clock.requestSchema, { ros2: true }));
        const reader = new MessageReader(parseDefinition(clock.response?.schema ?? clock.responseSchema, { ros2: true }));
        const t1 = BigInt(Date.now()) * 1000000n;
        client.on("serviceCallResponse", (response) => {
          const body = reader.readMessage(response.data);
          seen.clock = { echoed: body.t1 === t1, ordered: body.t2 <= body.t3 };
        });
        const request = writer.writeMessage({ t1 });
        client.sendServiceCallRequest({
          serviceId: clock.id,
          callId: 1,
          encoding: "cdr",
          data: new DataView(request.buffer, request.byteOffset, request.byteLength),
        });
      } catch (err) {
        problems.push(`clock_sync call failed: ${err.message}`);
      }
    });

    client.on("parameterValues", ({ parameters, id }) => {
      if (id === "get") {
        seen.parameters = parameters;
        client.setParameters([{ name: "color.rate", value: NEW_COLOR_RATE, type: "float64" }], "set");
      }
      if (id === "set") {
        seen.setResult = parameters;
        // 設定は端末に 1 つで、ほかの接続にも反映される。確かめ終えたら元の値へ戻す。
        const original = seen.parameters.find((p) => p.name === "color.rate");
        if (original) client.setParameters([original], "restore");
      }
    });
    client.on("open", () => client.getParameters([], "get"));

    setTimeout(() => {
      client.close();
      if (!seen.serverInfo?.supportedEncodings?.includes("cdr")) problems.push("serverInfo lacks supportedEncodings cdr");
      for (const capability of ["parameters", "parametersSubscribe", "services"]) {
        if (!seen.serverInfo?.capabilities?.includes(capability)) problems.push(`serverInfo lacks capability ${capability}`);
      }
      if (topics.size === 0) problems.push("no channel was advertised");
      for (const [topic, stat] of topics) {
        if (stat.count !== 0) continue;
        if (MAY_BE_SILENT.some((suffix) => topic.endsWith(suffix))) notes.push(`${topic}: no message within ${LISTEN_MS} ms`);
        else problems.push(`${topic}: no message within ${LISTEN_MS} ms`);
      }
      if (!seen.clock) problems.push("clock_sync did not answer");
      else if (!seen.clock.echoed || !seen.clock.ordered) problems.push(`clock_sync answered wrongly: ${JSON.stringify(seen.clock)}`);
      if (!seen.parameters?.some((p) => p.name === "color.rate")) problems.push("getParameters did not return color.rate");
      if (seen.setResult?.find((p) => p.name === "color.rate")?.value !== NEW_COLOR_RATE) {
        problems.push(`setParameters did not echo color.rate=${NEW_COLOR_RATE}: ${JSON.stringify(seen.setResult)}`);
      }
      resolve({ topics, problems, notes });
    }, LISTEN_MS);
  });
}

const given = process.argv[2];
const sim = given ? null : await startSim();
try {
  const { topics, problems, notes } = await check(given ?? sim.url);
  for (const [topic, stat] of topics) {
    console.log(`${String(stat.count).padStart(5)}  ${topic}  (${stat.schema})`);
  }
  for (const note of notes) {
    console.log(`NOTE: ${note}`);
  }
  for (const problem of problems) {
    console.error(`PROBLEM: ${problem}`);
  }
  console.log(problems.length === 0 ? "OK" : `${problems.length} problem(s)`);
  process.exitCode = problems.length === 0 ? 0 : 1;
} finally {
  sim?.proc.kill("SIGTERM");
}
