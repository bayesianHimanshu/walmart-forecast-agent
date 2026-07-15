'use client';
import { useEffect, useState } from 'react';
import Dashboard from '@/components/Dashboard';
import ForecastExplorer from '@/components/ForecastExplorer';
import AgentPanel from '@/components/AgentPanel';

interface Series {
  SERIES_KEY: string; STORE: number; DEPT: number; STORE_TYPE: string;
  CHAMPION_MODEL: string; BEST_IMPR_PCT: number;
}

export default function Page() {
  const [series, setSeries] = useState<Series[]>([]);
  const [kpis, setKpis] = useState<any>(null);
  const [mix, setMix] = useState<any[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    fetch('/api/series')
      .then((r) => r.json())
      .then((d) => {
        if (d.error) { setErr(d.error); return; }
        setSeries(d.series); setKpis(d.kpis); setMix(d.mix);
        if (d.series?.length) setSelected(d.series[0].SERIES_KEY);
      })
      .catch((e) => setErr(String(e)));
  }, []);

  return (
    <div className="app">
      <header className="topbar">
        <h1>Demand Forecasting</h1>
        <span className="sub">store × department · 8-week horizon · champion-per-series</span>
        <span className="badge">Powered by Snowflake Cortex</span>
      </header>

      {err && <div className="panel"><div className="bd" style={{ color: 'var(--warn)' }}>
        Couldn’t load data: {err}. Check that the pipeline (sql/01–07) has run and the service role can read WALMART_DEMO.FORECAST.
      </div></div>}

      <div className="grid">
        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
          <Dashboard kpis={kpis} mix={mix} />
          <div className="panel">
            <div className="hd">Series ({series.length})</div>
            <div className="bd" style={{ paddingTop: 8 }}>
              <div className="series-list">
                {series.map((s) => (
                  <div
                    key={s.SERIES_KEY}
                    className={'series-item' + (selected === s.SERIES_KEY ? ' active' : '')}
                    onClick={() => setSelected(s.SERIES_KEY)}
                  >
                    <span className="k">{s.SERIES_KEY}</span>
                    <span className={'tag' + (s.CHAMPION_MODEL !== 'SEASONAL_NAIVE' ? ' win' : '')}>
                      {s.CHAMPION_MODEL.replace('SNOWFLAKE_GBM_NATIVE', 'SF-GBM')}
                    </span>
                    <span className="m">Store {s.STORE} · Type {s.STORE_TYPE} · Dept {s.DEPT}</span>
                    <span className="m">{s.BEST_IMPR_PCT > 0 ? `+${s.BEST_IMPR_PCT}% vs naive` : 'baseline'}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>

        <div style={{ display: 'flex', flexDirection: 'column', gap: 20 }}>
          {selected && <ForecastExplorer series={selected} />}
          <AgentPanel selected={selected} />
        </div>
      </div>
    </div>
  );
}
