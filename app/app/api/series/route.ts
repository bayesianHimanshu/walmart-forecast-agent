import { NextResponse } from 'next/server';
import { runSql } from '@/lib/snowflake';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET() {
  try {
    const series = await runSql(
      `SELECT series_key, store, dept, store_type, sb_class,
              seas_strength, holiday_lift, mean_sales,
              champion_model, champion_wmae, naive_wmae, best_impr_pct
       FROM SERIES_SUMMARY
       ORDER BY store, dept`
    );
    const kpis = await runSql(
      `SELECT COUNT(*) AS SERIES,
              ROUND(AVG(best_impr_pct),1) AS AVG_IMPR,
              COUNT_IF(champion_model <> 'SEASONAL_NAIVE') AS MODELED,
              ROUND(SUM(mean_sales),0) AS WEEKLY_VOLUME
       FROM SERIES_SUMMARY`
    );
    const mix = await runSql(
      `SELECT champion_model AS MODEL, COUNT(*) AS N
       FROM SERIES_SUMMARY GROUP BY 1 ORDER BY 2 DESC`
    );
    return NextResponse.json({ series, kpis: kpis[0], mix });
  } catch (e: any) {
    return NextResponse.json({ error: String(e?.message || e) }, { status: 500 });
  }
}
