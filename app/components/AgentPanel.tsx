'use client';
import { useState } from 'react';

interface Msg { role: 'user' | 'bot'; text: string; sql?: string | null; thinking?: string; tools?: string[]; }

export default function AgentPanel({ selected }: { selected: string | null }) {
  const [log, setLog] = useState<Msg[]>([]);
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);

  const suggestions = [
    selected ? `What's the 8-week forecast for ${selected} and why that model?` : 'Which series have the highest forecasted sales?',
    'Which model wins most often, and where does SARIMA tend to win?',
    'How does champion selection work, and what is WMAE?',
    'Rank store types by average forecast accuracy improvement.',
  ];

  async function ask(question: string) {
    if (!question.trim() || busy) return;
    setLog((l) => [...l, { role: 'user', text: question }]);
    setQ('');
    setBusy(true);
    try {
      const r = await fetch('/api/agent', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ question }),
      });
      const d = await r.json();
      if (d.error) setLog((l) => [...l, { role: 'bot', text: `Error: ${d.error}` }]);
      else setLog((l) => [...l, { role: 'bot', text: d.answer || '(no answer)', sql: d.sql, thinking: d.thinking, tools: d.tools }]);
    } catch (e: any) {
      setLog((l) => [...l, { role: 'bot', text: `Error: ${String(e?.message || e)}` }]);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="panel agent">
      <div className="hd">Ask the forecasting agent</div>
      <div className="bd">
        {log.length === 0 && (
          <div className="chips">
            {suggestions.map((s, i) => (
              <button className="chip" key={i} onClick={() => ask(s)}>{s}</button>
            ))}
          </div>
        )}
        <div className="log">
          {log.map((m, i) => (
            m.role === 'user'
              ? <div className="msg user" key={i}>{m.text}</div>
              : <div className="msg bot" key={i}>
                  <div className="txt">{m.text}</div>
                  <div className="meta">
                    {m.tools && m.tools.length > 0 && <span>tools: {m.tools.join(', ')} · </span>}
                    {m.sql && <details><summary>view generated SQL</summary><pre>{m.sql}</pre></details>}
                  </div>
                </div>
          ))}
          {busy && <div className="msg bot"><div className="txt"><span className="spinner" /> <span className="muted">thinking…</span></div></div>}
        </div>
        <div className="ask">
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') ask(q); }}
            placeholder="Ask about forecasts, models, accuracy…"
          />
          <button disabled={busy || !q.trim()} onClick={() => ask(q)}>Ask</button>
        </div>
      </div>
    </div>
  );
}
