USE ROLE ACCOUNTADMIN;
USE WAREHOUSE WALMART_WH;
USE DATABASE WALMART_DEMO;
USE SCHEMA FORECAST;

CREATE OR REPLACE PROCEDURE RUN_FORECAST_MODELS(RUN_ID STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python','pandas','numpy','statsmodels','scikit-learn','lightgbm','prophet')
HANDLER = 'main'
AS
$$
import json, numpy as np, pandas as pd, datetime as dt

EXO = ["TEMPERATURE","FUEL_PRICE","CPI","UNEMPLOYMENT",
       "MARKDOWN1","MARKDOWN2","MARKDOWN3","MARKDOWN4","MARKDOWN5"]
HOLIDAYS = pd.to_datetime([
    "2010-02-12","2011-02-11","2012-02-10","2010-09-10","2011-09-09","2012-09-07",
    "2010-11-26","2011-11-25","2012-11-23","2010-12-31","2011-12-30","2012-12-28"])

# ---------- metrics ----------
def wmae(y,f,hol):
    w=np.where(hol,5.0,1.0); return float(np.sum(w*np.abs(y-f))/np.sum(w))

# ---------- models: fit on history df, predict for the future rows exf ----------
def m_naive(h, exf, H):
    y=h["WEEKLY_SALES"].values
    if len(y)>=52: return np.array([y[-52+i] if len(y)-52+i>=0 else y[-1] for i in range(H)])
    return np.repeat(y[-1], H)

def m_sarima(h, exf, H):
    from statsmodels.tsa.statespace.sarimax import SARIMAX
    y=h["WEEKLY_SALES"].values
    r=SARIMAX(y, order=(1,1,1), seasonal_order=(0,1,1,52),
              enforce_stationarity=False, enforce_invertibility=False).fit(disp=False, maxiter=50)
    return np.asarray(r.forecast(H))

def m_prophet(h, exf, H):
    from prophet import Prophet
    d=pd.DataFrame({"ds":h["WEEK_DATE"].values, "y":h["WEEKLY_SALES"].values})
    d["hol"]=d["ds"].isin(HOLIDAYS).astype(int)
    mp=Prophet(weekly_seasonality=False, daily_seasonality=False, yearly_seasonality=True)
    mp.add_regressor("hol"); mp.fit(d)
    fut=pd.DataFrame({"ds":pd.to_datetime(exf["WEEK_DATE"].values)})
    fut["hol"]=fut["ds"].isin(HOLIDAYS).astype(int)
    return mp.predict(fut)["yhat"].values

def _fe(d):
    d=d.copy(); d["woy"]=pd.to_datetime(d["WEEK_DATE"]).dt.isocalendar().week.astype(int)
    d["month"]=pd.to_datetime(d["WEEK_DATE"]).dt.month
    for L in (1,2,4,52): d[f"lag{L}"]=d["WEEKLY_SALES"].shift(L)
    return d

def m_gbm(h, exf, H):
    import lightgbm as lgb
    feats=["woy","month","lag1","lag2","lag4","lag52"]+EXO
    tr=_fe(h).dropna(subset=["lag52"])
    if len(tr)<20: return m_naive(h, exf, H)
    mdl=lgb.LGBMRegressor(n_estimators=200, max_depth=5, learning_rate=0.05, verbose=-1)
    mdl.fit(tr[feats], tr["WEEKLY_SALES"])
    cur=h.copy(); preds=[]
    for i in range(H):
        row=exf.iloc[[i]].copy()
        tmp=_fe(pd.concat([cur,row], ignore_index=True))
        x=tmp[feats].iloc[[-1]].ffill().fillna(0)
        p=float(mdl.predict(x)[0]); preds.append(p)
        row=row.copy(); row["WEEKLY_SALES"]=p
        cur=pd.concat([cur,row], ignore_index=True)
    return np.array(preds)

MODELS={"SEASONAL_NAIVE":m_naive,"SARIMA":m_sarima,"PROPHET":m_prophet,"GBM":m_gbm}

def _future_exog(h, future_dates):
    # carry forward last observed exogenous values (no true future values exist)
    last=h.iloc[-1]
    rows=[]
    for dts in future_dates:
        r={"WEEK_DATE":dts}
        for c in EXO: r[c]=last[c]
        rows.append(r)
    return pd.DataFrame(rows)

def main(session, run_id):
    cfg=session.table("BACKTEST_CONFIG").to_pandas().iloc[0]
    origins_raw = cfg["ORIGINS"]
    if isinstance(origins_raw, str):
        origins_raw = json.loads(origins_raw)          # ARRAY comes back as a JSON string
    H = int(cfg["HORIZON_WEEKS"]); origins = [int(x) for x in origins_raw]; Z = float(cfg["INTERVAL_Z"])

    df=session.table("SALES_WEEKLY_DEMO").to_pandas()
    df["WEEK_DATE"]=pd.to_datetime(df["WEEK_DATE"])
    df=df.sort_values(["SERIES_KEY","WEEK_DATE"])

    bt_rows=[]; fwd_rows=[]
    for skey, g in df.groupby("SERIES_KEY"):
        g=g.reset_index(drop=True); n=len(g)

        # ---- backtest ----
        for off in origins:
            cut=n-off
            if cut<60: continue
            hist=g.iloc[:cut]; win=g.iloc[cut:cut+H]
            if len(win)<H: continue
            origin_date=hist["WEEK_DATE"].iloc[-1].date()
            exf=win[["WEEK_DATE"]+EXO].reset_index(drop=True)
            y=win["WEEKLY_SALES"].values
            hol=win["WEEK_DATE"].isin(HOLIDAYS).values
            for name,fn in MODELS.items():
                try: f=fn(hist, exf, H)
                except Exception: f=m_naive(hist, exf, H)
                for step in range(H):
                    bt_rows.append((run_id,name,skey,origin_date,
                                    win["WEEK_DATE"].iloc[step].date(),step+1,
                                    float(y[step]),float(f[step]),bool(hol[step])))

        # ---- forward forecast (fit on full history) ----
        last_d=g["WEEK_DATE"].iloc[-1]
        fdates=[ (last_d+pd.Timedelta(weeks=k+1)) for k in range(H) ]
        exf_fut=_future_exog(g, fdates)
        for name,fn in MODELS.items():
            try: f=fn(g, exf_fut, H)
            except Exception: f=m_naive(g, exf_fut, H)
            # residual-based interval from an in-sample seasonal-naive residual proxy
            yv=g["WEEKLY_SALES"].values
            resid_std=float(np.std(yv[52:]-yv[:-52])) if len(yv)>52 else float(np.std(np.diff(yv)))
            for step in range(H):
                fwd_rows.append((run_id,name,skey,fdates[step].date(),step+1,
                                 float(f[step]),
                                 float(f[step]-Z*resid_std),
                                 float(f[step]+Z*resid_std)))

    bt=pd.DataFrame(bt_rows, columns=["RUN_ID","MODEL","SERIES_KEY","ORIGIN_DATE","TARGET_WEEK",
                                      "HORIZON_STEP","Y_TRUE","Y_PRED","IS_HOLIDAY"])
    fw=pd.DataFrame(fwd_rows, columns=["RUN_ID","MODEL","SERIES_KEY","TARGET_WEEK","HORIZON_STEP",
                                       "Y_PRED","Y_LOWER","Y_UPPER"])
    session.write_pandas(bt, "BACKTEST_FORECASTS", quote_identifiers=False)
    session.write_pandas(fw, "FORWARD_RAW", quote_identifiers=False)
    session.sql(f"INSERT INTO MODEL_RUNS(run_id,engine,note) "
                f"VALUES ('{run_id}','SNOWPARK','naive+sarima+prophet+gbm')").collect()
    return f"run {run_id}: {len(bt)} backtest rows, {len(fw)} forward rows"
$$;

-- Run it. Use a fresh run_id each time (append-only history).
CALL RUN_FORECAST_MODELS('run_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS'));

-- Peek
SELECT model, COUNT(*) nrows FROM BACKTEST_FORECASTS GROUP BY 1 ORDER BY 1;

/* Next: 04b_native_mlforecast_optional.sql  (optional: add Snowflake's native
   forecaster as a competitor), then 05_metrics_champion_rationale.sql */
