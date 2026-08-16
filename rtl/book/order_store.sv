`default_nettype none

module order_store #(
    parameter int SETS = 8192,
    parameter int WAYS = 16,
    parameter int TAG_LO = 13,
    parameter int TAG_BITS = 20,
    parameter int SHARES_W = 16
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic flush,
    output logic ready,
    input wire logic rec_valid,
    input wire logic [7:0] rec_type,
    input wire logic [63:0] rec_ref,
    input wire logic [63:0] rec_ref2,
    input wire logic [31:0] rec_shares,
    input wire logic [31:0] rec_price,
    input wire logic rec_side,
    input wire logic [1:0] rec_sym,
    output logic out_valid,
    output logic out_hit,
    output logic [1:0] out_sym,
    output logic out_side,
    output logic [31:0] out_price,
    output logic [SHARES_W-1:0] out_shares,
    output logic out_removed,
    output logic ovf_pulse,
    output logic miss_pulse,
    output logic dup_pulse,
    output logic [$clog2(SETS*WAYS+1)-1:0] occupancy
);

    localparam int IDX_W = $clog2(SETS);
    localparam int WAY_W = $clog2(WAYS);

    // {valid, tag, sym, side, price, shares}, shares in the low bits
    localparam int F_SHARES = 0;
    localparam int F_PRICE = F_SHARES + SHARES_W;
    localparam int F_SIDE = F_PRICE + 32;
    localparam int F_SYM = F_SIDE + 1;
    localparam int F_TAG = F_SYM + 2;
    localparam int F_VALID = F_TAG + TAG_BITS;
    localparam int ENTRY_W = F_VALID + 1;

    localparam logic [7:0] T_ADD = 8'h41;
    localparam logic [7:0] T_ADD_ATTR = 8'h46;
    localparam logic [7:0] T_EXEC = 8'h45;
    localparam logic [7:0] T_EXEC_PRICE = 8'h43;
    localparam logic [7:0] T_CANCEL = 8'h58;
    localparam logic [7:0] T_DELETE = 8'h44;
    localparam logic [7:0] T_REPLACE = 8'h55;

    // the index mixes three strips of the ref so a constant stride cannot land
    // every order in one set. Every strip above the offset sits inside the
    // stored tag, so the ref stays exactly recoverable and hits are not
    // probabilistic.
    function automatic logic [IDX_W-1:0] fold(input logic [63:0] r);
        fold = r[0 +: IDX_W] ^ r[IDX_W +: IDX_W] ^ r[2*IDX_W +: IDX_W];
    endfunction

    logic [ENTRY_W-1:0] rd [WAYS];
    logic [WAYS-1:0] wr_en;
    logic [IDX_W-1:0] rd_idx, wr_idx;
    logic [ENTRY_W-1:0] wr_data;

    // one array per way, read on the same address every cycle. Kept separate so
    // each stays inside the tool's per variable size limit and maps to its own
    // UltraRAM column.
    genvar w;
    generate
        for (w = 0; w < WAYS; w++) begin : g_way
            (* ram_style = "ultra" *)
            logic [ENTRY_W-1:0] mem [SETS];
            always_ff @(posedge clk) begin
                if (wr_en[w]) mem[wr_idx] <= wr_data;
                rd[w] <= mem[rd_idx];
            end
        end
    endgenerate

    // UltraRAM has no INIT, so every valid bit is garbage until walked to zero
    logic init_busy;
    logic [IDX_W-1:0] init_idx;

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            init_busy <= 1'b1;
            init_idx <= '0;
        end else if (init_busy) begin
            init_idx <= init_idx + 1'b1;
            if (init_idx == IDX_W'(SETS - 1)) init_busy <= 1'b0;
        end
    end

    // a replace is a delete then an insert, so the second half is replayed into
    // stage 0 from here while ready is held low
    logic pend_valid, pend_side;
    logic [63:0] pend_ref;
    logic [1:0] pend_sym;
    logic [31:0] pend_price;
    logic [SHARES_W-1:0] pend_shares;

    logic s0_go, hold, repl_hold;
    logic [7:0] s0_type;
    logic [63:0] s0_ref;
    logic [1:0] s0_sym;
    logic s0_side;
    logic [31:0] s0_price, s0_qty;
    logic [IDX_W-1:0] idx0;

    assign s0_type = pend_valid ? T_ADD : rec_type;
    assign s0_ref = pend_valid ? pend_ref : rec_ref;
    assign s0_sym = pend_valid ? pend_sym : rec_sym;
    assign s0_side = pend_valid ? pend_side : rec_side;
    assign s0_price = pend_valid ? pend_price : rec_price;
    assign s0_qty = pend_valid ? 32'(pend_shares) : rec_shares;

    assign idx0 = fold(s0_ref);
    assign rd_idx = idx0;

    logic s1_valid, s1_side;
    logic [7:0] s1_type;
    logic [IDX_W-1:0] s1_idx;
    logic [TAG_BITS-1:0] s1_tag;
    logic [1:0] s1_sym;
    logic [31:0] s1_price, s1_qty;
    logic [63:0] s1_ref2;

    logic [WAYS-1:0] hit, free;
    logic [WAY_W-1:0] hit_way, free_way;
    logic hit_any, free_any, is_add, is_reduce, is_del, is_repl, empties;
    logic [1:0] e_sym;
    logic e_side;
    logic [31:0] e_price;
    logic [SHARES_W-1:0] e_shares, qty, left;

    // stage 1 writes the set stage 0 is reading, so a second record on the same
    // index one cycle behind would see pre update data. One cycle of hold drains
    // it, which is why this module can backpressure at all.
    assign hold = s1_valid && (idx0 == s1_idx);

    // a replace claims the next slot for its own insert, and has to block the
    // input in the same cycle it is resolved. Waiting for pend_valid would be one
    // cycle late and let an unrelated record land between the two halves.
    assign repl_hold = s1_valid && is_repl && hit_any;

    assign ready = !init_busy && !pend_valid && !repl_hold && !hold;
    assign s0_go = (pend_valid || rec_valid) && !init_busy && !repl_hold && !hold;

    always_ff @(posedge clk) begin
        if (rst) s1_valid <= 1'b0;
        else s1_valid <= s0_go;
        s1_type <= s0_type;
        s1_idx <= idx0;
        s1_tag <= s0_ref[TAG_LO +: TAG_BITS];
        s1_sym <= s0_sym;
        s1_side <= s0_side;
        s1_price <= s0_price;
        s1_qty <= s0_qty;
        s1_ref2 <= rec_ref2;
    end

    always_comb begin
        logic [ENTRY_W-1:0] e;

        for (int i = 0; i < WAYS; i++) begin
            hit[i] = rd[i][F_VALID] && (rd[i][F_TAG +: TAG_BITS] == s1_tag);
            free[i] = !rd[i][F_VALID];
        end
        hit_any = |hit;
        free_any = |free;

        hit_way = '0;
        free_way = '0;
        for (int i = WAYS - 1; i >= 0; i--) begin
            if (hit[i]) hit_way = WAY_W'(i);
            if (free[i]) free_way = WAY_W'(i);
        end

        e = rd[hit_way];
        e_sym = e[F_SYM +: 2];
        e_side = e[F_SIDE];
        e_price = e[F_PRICE +: 32];
        e_shares = e[F_SHARES +: SHARES_W];

        is_add = (s1_type == T_ADD) || (s1_type == T_ADD_ATTR);
        is_reduce = (s1_type == T_EXEC) || (s1_type == T_EXEC_PRICE) || (s1_type == T_CANCEL);
        is_del = (s1_type == T_DELETE);
        is_repl = (s1_type == T_REPLACE);

        qty = |s1_qty[31:SHARES_W] ? '1 : s1_qty[SHARES_W-1:0];
        left = e_shares - qty;
        empties = (e_shares <= qty);

        wr_en = '0;
        wr_idx = s1_idx;
        wr_data = '0;
        if (init_busy) begin
            wr_en = '1;
            wr_idx = init_idx;
        end else if (s1_valid) begin
            if (is_add) begin
                if (free_any && !hit_any) begin
                    wr_en[free_way] = 1'b1;
                    wr_data = {1'b1, s1_tag, s1_sym, s1_side, s1_price, qty};
                end
            end else if (hit_any) begin
                if (is_del || is_repl) begin
                    wr_en[hit_way] = 1'b1;
                end else if (is_reduce) begin
                    wr_en[hit_way] = 1'b1;
                    if (!empties) wr_data = {1'b1, s1_tag, e_sym, e_side, e_price, left};
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) pend_valid <= 1'b0;
        else if (s1_valid && is_repl && hit_any) begin
            pend_valid <= 1'b1;
            pend_ref <= s1_ref2;
            pend_sym <= e_sym;
            pend_side <= e_side;
            pend_price <= s1_price;
            pend_shares <= qty;
        end else if (pend_valid && s0_go) begin
            pend_valid <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) occupancy <= '0;
        else if (s1_valid) begin
            if (is_add && free_any && !hit_any) occupancy <= occupancy + 1'b1;
            else if (hit_any && (is_del || is_repl || (is_reduce && empties)))
                occupancy <= occupancy - 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            out_valid <= 1'b0;
            ovf_pulse <= 1'b0;
            miss_pulse <= 1'b0;
            dup_pulse <= 1'b0;
        end else begin
            out_valid <= s1_valid;
            ovf_pulse <= s1_valid && is_add && !hit_any && !free_any;
            miss_pulse <= s1_valid && !is_add && !hit_any;
            dup_pulse <= s1_valid && is_add && hit_any;
        end
        out_hit <= is_add ? (free_any && !hit_any) : hit_any;
        out_sym <= is_add ? s1_sym : e_sym;
        out_side <= is_add ? s1_side : e_side;
        out_price <= is_add ? s1_price : e_price;
        out_shares <= is_add ? qty : e_shares;
        out_removed <= !is_add && hit_any && (is_del || is_repl || empties);
    end

endmodule

`default_nettype wire
