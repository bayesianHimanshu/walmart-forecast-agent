import { NextRequest, NextResponse } from 'next/server';
import { runSql } from '@/lib/snowflake';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(req: NextRequest) {
  const series = req.nextUrl.searchParams.get('series');
  if (!series) return NextResponse.json({ error: 'series required' }, { status: 400 });
  try {
    const summary = await runSql(
      `SELECT * FROM SERIES_SUMMARY WHERE series_key = ?`, [series]
    );
    // recent actuals (last ~40 weeks) for context
    const history = await runSql(
      `SELECT week_date AS WEEK, weekly_sales AS ACTUAL, is_holiday AS IS_HOLIDAY
       FROM SALES_WEEKLY_DEMO
       WHERE series_key = ?
       ORDER BY week_date DESC LIMIT 40`, [series]
    );
    const vsActual = await runSql(
      `SELECT target_week AS WEEK, actual AS ACTUAL, forecast AS FORECAST, is_holiday AS IS_HOLIDAY
       FROM FORECAST_VS_ACTUAL WHERE series_key = ? ORDER BY target_week`, [series]
    );
    const forward = await runSql(
      `SELECT target_week AS WEEK, forecast AS FORECAST, lower_80 AS LOWER, upper_80 AS UPPER
       FROM FUTURE_FORECASTS WHERE series_key = ? ORDER BY target_week`, [series]
    );
    const rationale = await runSql(
      `SELECT body FROM SERIES_RATIONALE WHERE series_key = ?`, [series]
    );
    return NextResponse.json({
      summary: summary[0],
      history: history.reverse(),
      vsActual,
      forward,
      rationale: rationale[0]?.BODY || '',
    });
  } catch (e: any) {
    return NextResponse.json({ error: String(e?.message || e) }, { status: 500 });
  }
}
