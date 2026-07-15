'use client';
import { useEffect, useState } from 'react';
import {
  ComposedChart, Line, Area, XAxis, YAxis, Tooltip, CartesianGrid, ResponsiveContainer, ReferenceLine, Legend,
} from 'recharts';

const fmtK = (n: number) => (n == null ? '' : '$' + Math.round(n / 1000) + 'k');
const fmtDate = (s: string) => { const d = new Date(s); return `${d.getMonth() + 1}/${d.getDate()}`; };
const modelLabel = (m: string) => (m || '').replace('SNOWFLAKE_GBM_NATIVE', 'Snowflake GBM');

export default function ForecastExplorer({ series }: { series: string }) {
  const [data, setData] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    setLoading(true);
    fetch(`/api/forecast?series=${encodeURIComponent(series)}`)
      .then((r) => r.json())
      .then((d) => setData(d))
      .finally(() => setLoading(false));
  }, [series]);

  if (loading) return <div className="panel"><div className="bd"><span className="spinner" /> <span className="muted">Loading forecast…</span></div></div>;
  if (!data || data.error) return <div className="panel"><div className="bd" style={{ color: 'var(--warn)' }}>{data?.error || 'No data'}</div></div>;

  const s = data.summary || {};
  const byWeek: Record<string, any> = {};
  for (const h of data.history || []) byWeek[h.WEEK] = { week: h.WEEK, actual: h.ACTUAL };
  for (const v of data.vsActual || []) byWeek[v.WEEK] = { ...(byWeek[v.WEEK] || { week: v.WEEK }), actual: v.ACTUAL, fit: v.FORECAST };
  for (const f of data.forward || []) byWeek[f.WEEK] = { ...(byWeek[f.WEEK] || { week: f.WEEK }), forecast: f.FORECAST, lower: f.LOWER, upper: f.UPPER };
  const chart = Object.values(byWeek).sort((a: any, b: any) => a.week.localeCompare(b.week));
  const firstForward = (data.forward || [])[0]?.WEEK;

  return (
    <div className="panel explorer">
      <div className="hd">Forecast</div>
      <div className="bd">
        <div className="headline">
          <h2>{series}</h2>
          <span className="tag win">{modelLabel(s.CHAMPION_MODEL)}</span>
          <span className="muted">Store {s.STORE} · Type {s.STORE_TYPE} · Dept {s.DEPT} · {s.SB_CLASS}</span>
        </div>
        <div className="metrics-row">
          <div className="metric"><div className="v">{s.BEST_IMPR_PCT > 0 ? `+${s.BEST_IMPR_PCT}%` : '—'}</div><div className="l">vs seasonal-naive</div></div>
          <div className="metric"><div className="v">{fmtK(s.CHAMPION_WMAE)}</div><div className="l">WMAE (backtest)</div></div>
          <div className="metric"><div className="v">{s.SEAS_STRENGTH}</div><div className="l">Seasonality</div></div>
          <div className="metric"><div className="v">{s.HOLIDAY_LIFT}×</div><div className="l">Holiday lift</div></div>
        </div>

        <div style={{ width: '100%', height: 320, marginTop: 10 }}>
          <ResponsiveContainer>
            <ComposedChart data={chart} margin={{ top: 8, right: 12, bottom: 4, left: 4 }}>
              <CartesianGrid stroke="#eef0ed" vertical={false} />
              <XAxis dataKey="week" tickFormatter={fmtDate} tick={{ fontSize: 11, fill: '#667069' }} minTickGap={24} />
              <YAxis tickFormatter={fmtK} tick={{ fontSize: 11, fill: '#667069' }} width={48} />
              <Tooltip
                formatter={(v: any) => (v == null ? '—' : '$' + Number(v).toLocaleString())}
                labelFormatter={(l) => new Date(l).toLocaleDateString()}
              />
              <Legend wrapperStyle={{ fontSize: 12 }} />
              {firstForward && <ReferenceLine x={firstForward} stroke="#b4682a" strokeDasharray="3 3" label={{ value: 'forecast', position: 'top', fontSize: 11, fill: '#b4682a' }} />}
              <Area type="monotone" dataKey="upper" stroke="none" fill="#e6f1ee" name="80% band" legendType="none" />
              <Area type="monotone" dataKey="lower" stroke="none" fill="#ffffff" legendType="none" />
              <Line type="monotone" dataKey="actual" name="Actual" stroke="#16201c" dot={false} strokeWidth={2} />
              <Line type="monotone" dataKey="fit" name="Model fit (backtest)" stroke="#0f6f5c" dot={false} strokeWidth={1.5} strokeDasharray="4 2" connectNulls />
              <Line type="monotone" dataKey="forecast" name="Forecast" stroke="#0f6f5c" dot={{ r: 2 }} strokeWidth={2.5} connectNulls />
            </ComposedChart>
          </ResponsiveContainer>
        </div>

        {data.rationale && <div className="rationale">{data.rationale}</div>}
      </div>
    </div>
  );
}
