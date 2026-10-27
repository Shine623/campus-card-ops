#!/usr/bin/env python3
"""
余额一致性检查

检查逻辑：
  1. 从流水表汇总每张卡的应有余额
  2. 与余额表比对
  3. 输出差异清单

踩坑：
  最初按「卡号+日期」分组，跨零点的交易对不上。
  23:59:59 的消费和 00:00:01 的回调，分属两天。
  解决：按交易时间而非回调时间分组，允许跨天容差 1 小时。

用法:
  python check_balance.py              # 完整检查
  python check_balance.py --quick      # 只查今日
  python check_balance.py --card 12345 # 查单张卡
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


def check_all(quick=False, card_no=None):
    """执行检查"""
    try:
        import pymysql
    except ImportError:
        print('[!] 需要 pymysql: pip install pymysql')
        sys.exit(1)

    try:
        conn = pymysql.connect(**DB_CONF,
                               cursorclass=pymysql.cursors.DictCursor)
    except Exception as e:
        print(f'[!] 数据库连接失败: {e}')
        sys.exit(1)

    with conn.cursor() as cur:
        # 构建条件
        where = []
        params = []
        if quick:
            # 只查今天（含前后 1 小时容差）
            today = datetime.now().date()
            start = datetime.combine(today, datetime.min.time()) - timedelta(hours=1)
            end = datetime.combine(today, datetime.min.time()) + timedelta(days=1, hours=1)
            where.append('tx_time BETWEEN %s AND %s')
            params.extend([start, end])
        if card_no:
            where.append('card_no = %s')
            params.append(card_no)

        where_sql = ('WHERE ' + ' AND '.join(where)) if where else ''

        # 1. 从流水汇总应有余额
        # 充值 +，消费 -，退款 +
        cur.execute(f"""
            SELECT card_no,
                   SUM(CASE
                       WHEN tx_type = 'RECHARGE' AND status = 'SUCCESS' THEN amount
                       WHEN tx_type = 'CONSUME'  AND status = 'SUCCESS' THEN -amount
                       WHEN tx_type = 'REFUND'   AND status = 'SUCCESS' THEN amount
                       ELSE 0
                   END) AS calc_balance,
                   COUNT(*) AS tx_count
            FROM transaction
            {where_sql}
            GROUP BY card_no
        """, params)

        calc = {r['card_no']: r for r in cur.fetchall()}

        # 2. 读余额表
        cur.execute("SELECT card_no, balance, updated_at FROM card_balance")
        actual = {r['card_no']: r for r in cur.fetchall()}

    conn.close()

    # 3. 比对
    diffs = []
    all_cards = set(calc.keys()) | set(actual.keys())

    for cno in all_cards:
        c = calc.get(cno, {'calc_balance': 0, 'tx_count': 0})
        a = actual.get(cno, {'balance': 0, 'updated_at': None})

        calc_bal = float(c['calc_balance'] or 0)
        actual_bal = float(a['balance'] or 0)

        diff = round(calc_bal - actual_bal, 2)
        if abs(diff) > 0.01:      # 允许 1 分钱误差
            diffs.append({
                'card_no': cno,
                'calc': calc_bal,
                'actual': actual_bal,
                'diff': diff,
                'tx_count': c['tx_count'],
                'updated_at': a['updated_at'],
            })

    # 4. 输出
    print('=' * 70)
    print('  余额一致性检查')
    print('=' * 70)
    print(f'  范围:     {"今日" if quick else "全量"}'
          f'{"  卡号: " + card_no if card_no else ""}')
    print(f'  卡片数:   {len(all_cards)}')
    print(f'  交易笔数: {sum(c["tx_count"] for c in calc.values())}')
    print(f'  差异卡数: {len(diffs)}')
    print()

    if not diffs:
        print('  [OK] 差异: 0，余额与流水一致')
        print()
        print('=' * 70)
        return 0

    # 按差异金额排序
    diffs.sort(key=lambda d: abs(d['diff']), reverse=True)

    print('  差异明细（按金额降序，前 20 条）：')
    print()
    print(f'  {"卡号":<16} {"应有余额":>12} {"实际余额":>12} '
          f'{"差异":>10} {"笔数":>6}')
    print('  ' + '-' * 66)

    for d in diffs[:20]:
        print(f'  {d["card_no"]:<16} {d["calc"]:>12.2f} {d["actual"]:>12.2f} '
              f'{d["diff"]:>+10.2f} {d["tx_count"]:>6}')

    if len(diffs) > 20:
        print(f'  ... 还有 {len(diffs) - 20} 张卡有差异')

    print()

    # 差异原因分析
    print('  可能原因：')
    total_diff = sum(d['diff'] for d in diffs)
    if total_diff > 0:
        print(f'    汇总差异 {total_diff:+.2f} 元（实际余额偏低）')
        print('    → 可能是充值回调失败，交易已扣款但未入账')
        print('    → 检查 PENDING 状态的充值记录')
    else:
        print(f'    汇总差异 {total_diff:+.2f} 元（实际余额偏高）')
        print('    → 可能是消费记录丢失，POS 机上传失败')
        print('    → 对比 POS 机本地日志与中心库流水数')

    print()
    print('=' * 70)
    return len(diffs)


def main():
    p = argparse.ArgumentParser(description='余额一致性检查')
    p.add_argument('--quick', action='store_true', help='只查今日')
    p.add_argument('--card', default=None, help='只查指定卡号')
    p.add_argument('--export', default=None, help='导出差异到 CSV')
    args = p.parse_args()

    count = check_all(quick=args.quick, card_no=args.card)
    sys.exit(0 if count == 0 else 1)


if __name__ == '__main__':
    main()
