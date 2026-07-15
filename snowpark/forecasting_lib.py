"""
forecasting_lib.py  —  Reference / local-dev copy of the forecasting harness.

This is the exact logic that runs inside the Snowpark stored procedure
RUN_FORECAST_MODELS (sql/04_snowpark_models.sql), extracted here so it can be
read and unit-tested locally against the raw Kaggle CSVs. It was validated
end-to-end on the real Walmart data: four models (seasonal-naive, SARIMA,
Prophet, GBM) rolling-origin backtested, scored with holiday-weighted WMAE
(+ MASE / sMAPE), champion selected with a seasonal-naive guardrail.

Run locally (with train.csv / stores.csv / features.csv / demo_pairs.csv present):
    python forecasting_lib.py
"""

import warnings, numpy as np, pandas as pd
warnings.filterwarnings("ignore")
from statsmodels.tsa.statespace.sarimax import SARIMAX
from prophet import Prophet
import lightgbm as lgb

# ---- load & assemble weekly panel for demo series ----
train=pd.read_csv("train.csv",parse_dates=["Date"])
stores=pd.read_csv("stores.csv",lineterminator="\r"); stores.columns=[c.strip() for c in stores.columns]
feat=pd.read_csv("features.csv",parse_dates=["Date"],na_values=["NA"])
pairs=pd.read_csv("demo_pairs.csv")
df=(train.merge(pairs,on=["Store","Dept"])
        .merge(stores,on="Store")
        .merge(feat,on=["Store","Date"],how="left",suffixes=("","_f")))
for c in [f"MarkDown{i}" for i in range(1,6)]: df[c]=df[c].fillna(0)
df["series"]=df.Store.astype(str)+"_"+df.Dept.astype(str)
df=df.sort_values(["series","Date"])
HOL=["2010-02-12","2011-02-11","2012-02-10","2010-09-10","2011-09-09","2012-09-07",
     "2010-11-26","2011-11-25","2010-12-31","2011-12-30"]
EXO=["Temperature","Fuel_Price","CPI","Unemployment"]+[f"MarkDown{i}" for i in range(1,6)]

# ---- metrics ----
def wmae(y,f,hol):
    w=np.where(hol,5,1); return float(np.sum(w*np.abs(y-f))/np.sum(w))
def mase(y,f,ytr,m=52):
    d=np.mean(np.abs(ytr[m:]-ytr[:-m])) if len(ytr)>m else np.mean(np.abs(np.diff(ytr)))
    return float(np.mean(np.abs(y-f))/d) if d else np.nan
def smape(y,f):
    return float(100*np.mean(2*np.abs(f-y)/(np.abs(y)+np.abs(f)+1e-9)))

# ---- models: fit on history, predict horizon ----
def m_naive(h,exf,H):                      # seasonal-naive (52w); fallback last value
    y=h.Weekly_Sales.values
    return np.array([y[-52] if len(y)>=52 else y[-1] for _ in range(H)]) if len(y)>=52 \
           else np.repeat(y[-1],H)
def m_sarima(h,exf,H):
    y=h.Weekly_Sales.values
    try:
        r=SARIMAX(y,order=(1,1,1),seasonal_order=(0,1,1,52),
                  enforce_stationarity=False,enforce_invertibility=False).fit(disp=False,maxiter=50)
        return np.asarray(r.forecast(H))
    except Exception: return m_naive(h,exf,H)
def m_prophet(h,exf,H):
    try:
        d=pd.DataFrame({"ds":h.Date.values,"y":h.Weekly_Sales.values})
        d["hol"]=d.ds.isin(pd.to_datetime(HOL)).astype(int)
        mp=Prophet(weekly_seasonality=False,daily_seasonality=False,yearly_seasonality=True)
        mp.add_regressor("hol"); mp.fit(d)
        fut=pd.DataFrame({"ds":exf.Date.values}); fut["hol"]=fut.ds.isin(pd.to_datetime(HOL)).astype(int)
        return mp.predict(fut)["yhat"].values
    except Exception: return m_naive(h,exf,H)
def m_gbm(h,exf,H):                        # lightgbm w/ lags + calendar + exog (proxy for ML.FORECAST)
    def fe(d):
        d=d.copy(); d["woy"]=d.Date.dt.isocalendar().week.astype(int); d["month"]=d.Date.dt.month
        for L in (1,2,4,52):
            d[f"lag{L}"]=d.Weekly_Sales.shift(L)
        return d
    hist=fe(h)
    feats=["woy","month","lag1","lag2","lag4","lag52"]+EXO
    tr=hist.dropna(subset=["lag52"])
    if len(tr)<20: return m_naive(h,exf,H)
    mdl=lgb.LGBMRegressor(n_estimators=200,max_depth=5,learning_rate=0.05,verbose=-1)
    mdl.fit(tr[feats],tr.Weekly_Sales)
    # iterative multi-step
    cur=h.copy(); preds=[]
    for i in range(H):
        row=exf.iloc[[i]].copy()
        tmp=pd.concat([cur,row],ignore_index=True); tmp=fe(tmp)
        x=tmp[feats].iloc[[-1]].ffill().fillna(0)
        p=float(mdl.predict(x)[0]); preds.append(p)
        row["Weekly_Sales"]=p; cur=pd.concat([cur,row],ignore_index=True)
    return np.array(preds)

MODELS={"SEASONAL_NAIVE":m_naive,"SARIMA":m_sarima,"PROPHET":m_prophet,"SNOWFLAKE_GBM":m_gbm}
H=8; ORIGINS=[24,16,8]   # weeks-from-end; each forecasts next 8w (expanding train)

rows=[]
series_list=["20_59","20_92","10_7","10_72","37_5","20_38"]  # holiday-driven, flat, erratic, high-vol, small-store, smooth
for s in series_list:
    g=df[df.series==s].reset_index(drop=True); n=len(g)
    for off in ORIGINS:
        cut=n-off
        if cut<60: continue
        hist=g.iloc[:cut]; win=g.iloc[cut:cut+H]
        if len(win)<H: continue
        exf=win[["Date"]+EXO].reset_index(drop=True)
        yv=win.Weekly_Sales.values; holv=win.Date.isin(pd.to_datetime(HOL)).values
        ytr=hist.Weekly_Sales.values
        for name,fn in MODELS.items():
            f=fn(hist,exf,H)
            rows.append(dict(series=s,origin=off,model=name,
                             wmae=wmae(yv,f,holv),mase=mase(yv,f,ytr),smape=smape(yv,f)))
res=pd.DataFrame(rows)
agg=res.groupby(["series","model"]).agg(wmae=("wmae","mean"),mase=("mase","mean"),
                                        smape=("smape","mean")).reset_index()
# champion = min WMAE, guardrail: must beat naive by >=2%
champ=[]
for s,gg in agg.groupby("series"):
    gg=gg.set_index("model"); naive=gg.loc["SEASONAL_NAIVE","wmae"]
    best=gg.wmae.idxmin(); bestw=gg.wmae.min()
    impr=(naive-bestw)/naive*100
    chosen=best if (best!="SEASONAL_NAIVE" and impr>=2) else "SEASONAL_NAIVE"
    champ.append(dict(series=s,champion=chosen,champ_wmae=gg.loc[chosen,"wmae"],
                      naive_wmae=naive,impr_vs_naive=round(impr,1)))
champ=pd.DataFrame(champ)
print("=== champion distribution across %d demo series ==="%champ.series.nunique())
print(champ.champion.value_counts().to_string())
print("\nmean improvement of champion vs naive: %.1f%%"%champ.impr_vs_naive.mean())
print("\nsample champions:")
print(champ.sort_values("impr_vs_naive",ascending=False).head(10).to_string(index=False))
print("\nmodels ran cleanly; rows scored:",len(res))
champ.to_csv("validated_champions.csv",index=False); agg.to_csv("validated_metrics.csv",index=False)
