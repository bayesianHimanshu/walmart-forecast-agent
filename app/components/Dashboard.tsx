'use client';

function money(n: number) {
  if (n == null) return '—';
  if (n >= 1e6) return '$' + (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return '$' + (n / 1e3).toFixed(0) + 'k';
  return '$' + n;
}

export default function Dashboard({ kpis, mix }: { kpis: any; mix: any[] }) {
  const total = (mix || []).reduce((a, m) => a + Number(m.N), 0) || 1;
  return (
    <div className="panel">
      <div className="hd">Portfolio</div>
      <div className="bd">
        <div className="kpis">
          <div className="kpi"><div className="v">{kpis?.SERIES ?? '—'}</div><div className="l">Series</div></div>
          <div className="kpi"><div className="v">{kpis?.MODELED ?? '—'}</div><div className="l">Beating baseline</div></div>
          <div className="kpi"><div className="v">{kpis?.AVG_IMPR != null ? kpis.AVG_IMPR + '%' : '—'}</div><div className="l">Avg gain vs naive</div></div>
          <div className="kpi"><div className="v">{money(Number(kpis?.WEEKLY_VOLUME))}</div><div className="l">Weekly volume</div></div>
        </div>
        <div className="mix">
          {(mix || []).map((m) => (
            <div className="row" key={m.MODEL}>
              <span>{m.MODEL.replace('SNOWFLAKE_GBM_NATIVE', 'Snowflake GBM')}</span>
              <span className="bar"><i style={{ width: `${(Number(m.N) / total) * 100}%` }} /></span>
              <span className="muted" style={{ textAlign: 'right' }}>{m.N}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
