// Calls the Cortex Agent through the SQL function SNOWFLAKE.CORTEX.DATA_AGENT_RUN
// (same interface everything else in this repo uses — no separate REST endpoint
// to configure). Parses the structured response into the pieces the UI shows.
import { runSql } from './snowflake';

const AGENT = 'WALMART_DEMO.FORECAST.WALMART_FORECAST_AGENT';

export interface AgentReply {
  answer: string;        // final natural-language answer
  sql: string | null;    // SQL the Analyst tool generated (if any)
  thinking: string;      // orchestration reasoning (if surfaced)
  tools: string[];       // names of tools invoked
}

function textFromContent(content: any[]): { answer: string; sql: string | null; thinking: string; tools: string[] } {
  let answer = '';
  let sql: string | null = null;
  let thinking = '';
  const tools: string[] = [];

  for (const block of content || []) {
    const type = block?.type;
    if (type === 'text' && block.text) {
      answer += block.text;
    } else if (type === 'thinking' && block.thinking) {
      thinking += block.thinking;
    } else if (type === 'tool_use' && block.tool_use?.name) {
      tools.push(block.tool_use.name);
    } else if (type === 'tool_result') {
      // Analyst tool results carry the generated SQL in json.sql
      const json = block.tool_result?.content?.find?.((c: any) => c.type === 'json')?.json;
      if (json?.sql) sql = json.sql;
    }
  }
  return { answer: answer.trim(), sql, thinking: thinking.trim(), tools };
}

export async function askAgent(question: string): Promise<AgentReply> {
  const payload = {
    messages: [{ role: 'user', content: [{ type: 'text', text: question }] }],
  };
  // DATA_AGENT_RUN returns a VARIANT; we alias it and read the single row/column.
  const rows = await runSql<any>(
    `SELECT SNOWFLAKE.CORTEX.DATA_AGENT_RUN(?, PARSE_JSON(?)) AS RESP`,
    [AGENT, JSON.stringify(payload)]
  );
  const raw = rows?.[0]?.RESP;
  const resp = typeof raw === 'string' ? JSON.parse(raw) : raw;
  const content = resp?.content || resp?.messages?.slice(-1)?.[0]?.content || [];
  return textFromContent(content);
}
