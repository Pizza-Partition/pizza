// Session IDs locate root-owned reports; they never grant execution authority.
const ID_PATTERN = /^[a-f0-9]{64}$/;
export const executionPending = (s) => ['prepared', 'running'].includes(s.status);
export class ExecutionMonitor {
  // Browser timers require Window as their receiver. Do not store the native
  // functions directly: this.schedule()/this.unschedule() changes that receiver.
  constructor({request, onUpdate: on_update, onDisconnected: on_disconnected, remember = () => {}, delay = 800, schedule = (fn, ms) => globalThis.setTimeout(fn, ms), unschedule = (id) => globalThis.clearTimeout(id)}) {
    Object.assign(this, {request, onUpdate: on_update, onDisconnected: on_disconnected, remember, delay, schedule, unschedule});
    this.generation = 0;
  }
  stop() { this.generation++; this.unschedule(this.timer); }
  watch(session) {
    this.stop();
    this.id = session.id;
    this.digest = session.plan_digest;
    this.receive(session, this.generation);
  }
  receive(session, generation) {
    if (generation !== this.generation) return;
    if (!ID_PATTERN.test(session.id) || (this.id && session.id !== this.id) || (this.digest && session.plan_digest !== this.digest)) throw Error('The execution session does not match.');
    this.id = session.id;
    this.remember(session.id, session.plan_digest);
    this.onUpdate(session);
    if (executionPending(session)) this.timer = this.schedule(() => this.refresh(), this.delay);
  }
  async resume(id, elevated = false, digest) {
    this.stop();
    if (id != null && !ID_PATTERN.test(id)) throw Error('Invalid execution session.');
    this.id = id;
    if (digest !== undefined) this.digest = digest;
    return this.fetch('/api/status', elevated);
  }
  refresh() { return this.fetch('/api/status', false); }
  async cancel() {
    this.stop(); // Ignore any status response already in flight.
    return this.fetch('/api/cancel', false);
  }
  async fetch(path, elevated) {
    const generation = this.generation;
    try {
      const session = await this.request(path, {...(this.id ? {session_id: this.id} : {}), elevated, ...(this.digest ? {approved_digest:this.digest} : {})});
      this.receive(session, generation);
    } catch (error) {
      if (generation === this.generation) {
        this.stop();
        this.onDisconnected(error, this.id);
      }
    }
  }
}
