import { Socket } from "phoenix";
import { storedToken } from "@/api/client";

export function subscribeToCase(caseId: string, changed: () => void) {
  const token = storedToken();
  if (!caseId || !token) return () => undefined;

  const socket = new Socket("/socket");
  socket.connect();
  const channel = socket.channel(`case:${caseId}`, { token });

  channel.on("changed", changed);
  channel.join().receive("ok", changed).receive("error", changed);

  return () => {
    channel.leave();
    socket.disconnect();
  };
}
