#!/usr/bin/env python3
"""
自动对账

比对「交易流水」与「账务流水」，生成差异工单。

对账逻辑：
  1. 按 (卡号, 日期) 汇总两个表
  2. 比对金额与笔数
  3. 不一致的生成工单

用法:
  python reconcile.py --date 2026-06-15
  python reconcile.py --start 2026-06-01 --end 2026-06-15
"""
import argparse
import sys
from datetime import datetime, timedelta

DB_CONF = {
    'host': '127.0.0.1',
    'user': 'card',
    'password': 'card123',
    'database': 'card',
    'charset': 'utf8mb4',
}


def reconcile(start_date, end_date, export=None):
    try:
        import pymysql
    except ImportError:
        print('[!] 需要 pymysql')
        sys.exit(1)

    try:
        conn = pymysql.connect(**DB_CONF,
                               cursorclass=pymysql.cursors.DictCursor)
    except Exception as e:
        print(f'[!] 数据库连接失败: {e}')
        sys.exit(1)

    with conn.cursor() as cur:
        # ---------- 交易流水 ----------
        # 按交易时间分组（不是回调时间！）
        cur.execute("""
            SELECT card_no,
                   DATE(tx_time) AS tx_date,
                   COUNT(*) AS tx_count,
                   SUM(CASE WHEN tx_type='CONSUME' THEN amount ELSE 0 END) AS consume_amt,
                   SUM(CASE WHEN tx_type='RECHARGE' THEN amount ELSE 0 END) AS recharge_amt
            FROM transaction
            WHERE tx_time >= %s
              AND tx_time < %s
              AND status = 'SUCCESS'
            GROUP BY card_no, DATE(tx_time)
        """, [start_date, end_date + timedelta(days=1)])

        tx_map = {}
        for r in cur.fetchall():
            key = (r['card_no'], r['tx_date'])
            tx_map[key] = r

        # ---------- 账务流水 ----------
        cur.execute("""
            SELECT card_no,
                   DATE(log_time) AS log_date,
                   COUNT(*) AS log_count,
                   SUM(CASE WHEN direction='OUT' THEN amount ELSE 0 END) AS out_amt,
                   SUM(CASE WHEN direction='IN' THEN amount ELSE 0 END) AS in_amt
            FROM account_log
            WHERE log_time >= %s
              AND log_time < %s
            GROUP BY card_no, DATE(log_time)
        """, [start_date, end_date + timedelta(days=1)])

        log_map = {}
        for r in cur.fetchall():
            key = (r['card_no'], r['log_date'])
            log_map[key] = r

    conn.close()

    # ---------- 比对 ----------
    diffs = []
    all_keys = set(tx_map.keys()) | set(log_map.keys())

    for key in all_keys:
        card_no, d = key
        tx = tx_map.get(key, {
            'tx_count': 0, 'consume_amt': 0, 'recharge_amt': 0
        })
        lg = log_map.get(key, {
            'log_count': 0, 'out_amt': 0, 'in_amt': 0
        })

        tx_count = int(tx['tx_count'])
        log_count = int(lg['log_count'])
        tx_out = float(tx['consume_amt'] or 0)
        log_out = float(lg['out_amt'] or 0)
        tx_in = float(tx['recharge_amt'] or 0)
        log_in = float(lg['in_amt'] or 0)

        # 笔数或金额不一致
        if tx_count != log_count or abs(tx_out - log_out) > 0.01 \
           or abs(tx_in - log_in) > 0.01:
            diffs.append({
                'card_no': card_no,
                'date': str(d),
                'tx_count': tx_count,
                'log_count': log_count,
                'count_diff': tx_count - log_count,
                'tx_out': tx_out,
                'log_out': log_out,
                'out_diff': round(tx_out - log_out, 2),
                'tx_in': tx_in,
                'log_in': log_in,
                'in_diff': round(tx_in - log_in, 2),
            })

    # ---------- 输出 ----------
    print('=' * 90)
    print('  一卡通对账')
    print('=' * 90)
    print(f'  区间:     {start_date} ~ {end_date}')
    print(f'  交易记录: {sum(int(t["tx_count"]) for t in tx_map.values())} 笔')
    print(f'  账务记录: {sum(int(l["log_count"]) for l in log_map.values())} 笔')
    print(f'  差异记录: {len(diffs)} 条')
    print()

    if not diffs:
        print('  [OK] 对账一致')
        print()
        print('=' * 90)
        return 0

    diffs.sort(key=lambda d: abs(d['out_diff']) + abs(d['in_diff']), reverse=True)

    print(f'  {"卡号":<14} {"日期":<12} {"笔数差":>7} {"消费差":>12} {"充值差":>12}')
    print('  ' + '-' * 62)

    for d in diffs[:30]:
        print(f'  {d["card_no"]:<14} {d["date"]:<12} {d["count_diff"]:>+7} '
              f'{d["out_diff"]:>+12.2f} {d["in_diff"]:>+12.2f}')

    if len(diffs) > 30:
        print(f'  ... 还有 {len(diffs) - 30} 条')

    print()

    # ---------- 生成工单 ----------
    print('  生成差异工单...')

    try:
        conn = pymysql.connect(**DB_CONF)
        with conn.cursor() as cur:
            for d in diffs:
                cur.execute("""
                    INSERT INTO reconcile_issue
                        (card_no, issue_date, tx_count, log_count,
                         out_diff, in_diff, status, created_at)
                    VALUES (%s, %s, %s, %s, %s, %s, 0, NOW())
                    ON DUPLICATE KEY UPDATE
                        tx_count = VALUES(tx_count),
                        log_count = VALUES(log_count),
                        out_diff = VALUES(out_diff),
                        in_diff = VALUES(in_diff)
                """, [d['card_no'], d['date'], d['tx_count'], d['log_count'],
                      d['out_diff'], d['in_diff']])
        conn.commit()
        conn.close()
        print(f'  [OK] 已生成 {len(diffs)} 条工单')
    except Exception as e:
        print(f'  [!] 工单生成失败: {e}')

    # ---------- 导出 ----------
    if export:
        try:
            import pandas as pd
            df = pd.DataFrame(diffs)
            df.to_csv(export, index=False, encoding='utf-8-sig')
            print(f'  [OK] 差异清单已导出: {export}')
        except ImportError:
            print('  [!] 需要 pandas')

    print()
    print('  差异原因分析：')
    total_out = sum(d['out_diff'] for d in diffs)
    total_in = sum(d['in_diff'] for d in diffs)

    if abs(total_out) > 0.01:
        print(f'    消费差异合计 {total_out:+.2f} 元')
        if total_out > 0:
            print('    → 交易流水多于账务流水，可能是账务记账失败')
        else:
            print('    → 账务流水多于交易流水，可能是重复记账')

    if abs(total_in) > 0.01:
        print(f'    充值差异合计 {total_in:+.2f} 元')
        if total_in > 0:
            print('    → 充值成功但未记账，检查回调')
        else:
            print('    → 账务有充值记录但交易表没有，可能是补单重复')

    print()
    print('=' * 90)
    return len(diffs)


def main():
    p = argparse.ArgumentParser(description='一卡通自动对账')
    p.add_argument('--date', default=None, help='对账日期（默认昨天）')
    p.add_argument('--start', default=None, help='起始日期')
    p.add_argument('--end', default=None, help='结束日期')
    p.add_argument('--export', default=None, help='导出 CSV')
    args = p.parse_args()

    if args.date:
        start = end = datetime.strptime(args.date, '%Y-%m-%d').date()
    elif args.start and args.end:
        start = datetime.strptime(args.start, '%Y-%m-%d').date()
        end = datetime.strptime(args.end, '%Y-%m-%d').date()
    else:
        end = (datetime.now() - timedelta(days=1)).date()
        start = end

    count = reconcile(start, end, args.export)
    sys.exit(0 if count == 0 else 1)


if __name__ == '__main__':
    main()
