import { NextRequest, NextResponse } from 'next/server';
import { askAgent } from '@/lib/agent';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function POST(req: NextRequest) {
  try {
    const { question } = await req.json();
    if (!question) return NextResponse.json({ error: 'question required' }, { status: 400 });
    const reply = await askAgent(question);
    return NextResponse.json(reply);
  } catch (e: any) {
    return NextResponse.json({ error: String(e?.message || e) }, { status: 500 });
  }
}
