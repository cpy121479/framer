`uvm_analysis_imp_decl(_in)
`uvm_analysis_imp_decl(_out)

// scoreboard：KOA 输出参考模型（8 优先级队列 + 组间 SP + 组内 FIFO）
// - 输入事件按 pri（0..7）入 8 个优先级队列（FIFO，先到先出）
// - 输出事件：组间 SP 选最高非空组（组号最小），组内 FIFO 出队；比对组号/数据
// - 保序由 THM 侧负责（KOA 不保序），本 scoreboard 不校验保序键
class koa_scoreboard extends uvm_scoreboard;
  uvm_analysis_imp_in   #(koa_item, koa_scoreboard) in_imp;
  uvm_analysis_imp_out  #(koa_item, koa_scoreboard) out_imp;

  localparam int N_PRI = 8;
  localparam int MAXQ  = 64;

  koa_item all_ev[$];
  koa_item q_items[N_PRI][MAXQ];
  int      q_head[N_PRI], q_tail[N_PRI], q_cnt[N_PRI];
  int      peak_q_occ;
  int      in_cnt, out_cnt;
  int      n_mismatch;
  `uvm_component_utils(koa_scoreboard)

  function new(string name = "koa_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    in_imp  = new("in_imp", this);
    out_imp = new("out_imp", this);
  endfunction

  function void write_in(koa_item it);
    if (it.is_out) return;
    all_ev.push_back(it);
    in_cnt++;
  endfunction

  function void write_out(koa_item it);
    if (!it.is_out) return;
    all_ev.push_back(it);
    out_cnt++;
  endfunction

  function void check_phase(uvm_phase phase);
    string fnames[7];
    fnames = '{"OH_EXT","OH_INS","APS_EXT","APS_INS","ALM","UART_EXT","UART_INS"};
    // 按时间戳稳定排序
    for (int i = 1; i < all_ev.size(); i++) begin
      koa_item key = all_ev[i];
      int j = i - 1;
      while (j >= 0 && all_ev[j].ev_time > key.ev_time) begin
        all_ev[j+1] = all_ev[j];
        j--;
      end
      all_ev[j+1] = key;
    end
    // 模拟
    foreach (all_ev[i]) begin
      if (!all_ev[i].is_out) begin
        int g = all_ev[i].pri;
        if (q_cnt[g] == MAXQ) begin
          `uvm_error("SCB", $sformatf("优先级队列 %0d 满（输入超限）", g))
          n_mismatch++;
        end else begin
          q_items[g][q_tail[g]] = all_ev[i];
          q_tail[g] = (q_tail[g] == MAXQ-1) ? 0 : q_tail[g] + 1;
          q_cnt[g] = q_cnt[g] + 1;
          if (q_cnt[g] > peak_q_occ) peak_q_occ = q_cnt[g];
        end
      end else begin
        int g = -1;
        for (int p = 0; p < N_PRI && g == -1; p++)
          if (q_cnt[p] != 0) g = p;
        if (g == -1) begin
          `uvm_error("SCB", $sformatf("输出 KO 时所有优先级队列为空（@%0t）", all_ev[i].ev_time))
          n_mismatch++;
          continue;
        end
        if (all_ev[i].sbuf !== g)
          `uvm_error("SCB", $sformatf("优先级组不符：输出组%0d 期望组%0d（@%0t）",
                     all_ev[i].sbuf, g, all_ev[i].ev_time))
        if (all_ev[i].ko_data !== q_items[g][q_head[g]].ko_data)
          `uvm_error("SCB", $sformatf("KO 数据不符（组%0d，@%0t）", g, all_ev[i].ev_time))
        n_mismatch += (all_ev[i].sbuf !== g) +
                      (all_ev[i].ko_data !== q_items[g][q_head[g]].ko_data);
        q_head[g] = (q_head[g] == MAXQ-1) ? 0 : q_head[g] + 1;
        q_cnt[g] = q_cnt[g] - 1;
      end
    end
    if (in_cnt != out_cnt)
      `uvm_error("SCB", $sformatf("数量不守恒：输入=%0d 输出=%0d", in_cnt, out_cnt))
    for (int p = 0; p < N_PRI; p++)
      if (q_cnt[p] != 0)
        `uvm_error("SCB", $sformatf("优先级队列 %0d 未清空：%0d 条", p, q_cnt[p]))
    `uvm_info("SCB", $sformatf("输入=%0d 输出=%0d，错配=%0d，优先级队列峰值占用=%0d",
             in_cnt, out_cnt, n_mismatch, peak_q_occ), UVM_LOW)
    for (int f = 0; f < 7; f++)
      if (ko_pkg::g_tb_cfg.bp_clks[f] != 0)
        `uvm_info("SCB", $sformatf("反压[%0s]: 事件%0d 次，共%0d 拍（%.1f%% 窗口）",
                   fnames[f], ko_pkg::g_tb_cfg.bp_events[f], ko_pkg::g_tb_cfg.bp_clks[f],
                   100.0 * ko_pkg::g_tb_cfg.bp_clks[f] / (ko_pkg::g_tb_cfg.run_us * 1000.0)),
                   UVM_LOW)
  endfunction
endclass
