`default_nettype none

module price_level #(
    parameter int SETS = 4096,
    parameter int WAYS = 8,
    parameter int DELTA_W = 21,
    parameter int QTY_W = 32
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic flush,
    output logic ready,
    input wire logic upd_valid,
    input wire logic [1:0] upd_sym,
    input wire logic upd_side,
    input wire logic [31:0] upd_price,
    input wire logic signed [DELTA_W-1:0] upd_delta,
    output logic lvl_valid,
    output logic [1:0] lvl_sym,
    output logic lvl_side,
    output logic [31:0] lvl_price,
    output logic [QTY_W-1:0] lvl_qty,
    output logic ovf_pulse,
    output logic miss_pulse,
    output logic [$clog2(SETS*WAYS+1)-1:0] occupancy
);

    localparam int IDX_W = $clog2(SETS);
    localparam int WAY_W = $clog2(WAYS);

    localparam int K_PRICE = 0;
    localparam int K_SIDE = 32;
    localparam int K_SYM = 33;
    localparam int KEY_W = K_SYM + 2;

    localparam int F_QTY = 0;
    localparam int F_KEY = QTY_W;
    localparam int F_VALID = F_KEY + KEY_W;
    localparam int ENTRY_W = F_VALID + 1;

    // the whole key is stored, so a match is exact and the fold only has to
    // spread sets. Ticks are multiples of 100 in ITCH price units, so the low
    // bits alone would leave most sets empty.
    function automatic logic [IDX_W-1:0] fold(input logic [KEY_W-1:0] k);
        fold = '0;
        for (int i = 0; i < KEY_W; i += IDX_W)
            fold = fold ^ IDX_W'(k >> i);
    endfunction

    logic [ENTRY_W-1:0] rd [WAYS];
    logic [WAYS-1:0] wr_en;
    logic [IDX_W-1:0] rd_idx, wr_idx;
    logic [ENTRY_W-1:0] wr_data;

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

    logic [KEY_W-1:0] key0;
    logic [IDX_W-1:0] idx0;
    logic act, hold;

    assign key0 = {upd_sym, upd_side, upd_price};
    assign idx0 = fold(key0);
    assign rd_idx = idx0;
    assign act = |upd_delta;

    logic s1_valid;
    logic [KEY_W-1:0] s1_key;
    logic [IDX_W-1:0] s1_idx;
    logic signed [DELTA_W-1:0] s1_delta;

    logic [WAYS-1:0] hit, free;
    logic [WAY_W-1:0] hit_way, free_way;
    logic hit_any, free_any;
    logic [QTY_W-1:0] sel_qty;

    logic s2_valid, s2_hit, s2_free;
    logic [KEY_W-1:0] s2_key;
    logic [IDX_W-1:0] s2_idx;
    logic signed [DELTA_W-1:0] s2_delta;
    logic [WAY_W-1:0] s2_hit_way, s2_free_way;
    logic [QTY_W-1:0] s2_qty;

    logic add, empties, applied;
    logic [QTY_W-1:0] new_qty;
    logic signed [QTY_W:0] sum;

    // the writeback leaves stage 2, so a record entering stage 0 reads memory
    // before either of the two ahead of it has written
    assign hold = (s1_valid && (idx0 == s1_idx)) || (s2_valid && (idx0 == s2_idx));
    assign ready = !init_busy && !hold;

    always_ff @(posedge clk) begin
        if (rst) s1_valid <= 1'b0;
        else s1_valid <= upd_valid && act && !init_busy && !hold;
        s1_key <= key0;
        s1_idx <= idx0;
        s1_delta <= upd_delta;
    end

    always_comb begin
        for (int i = 0; i < WAYS; i++) begin
            hit[i] = rd[i][F_VALID] && (rd[i][F_KEY +: KEY_W] == s1_key);
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

        sel_qty = rd[hit_way][F_QTY +: QTY_W];
    end

    always_ff @(posedge clk) begin
        if (rst) s2_valid <= 1'b0;
        else s2_valid <= s1_valid;
        s2_key <= s1_key;
        s2_idx <= s1_idx;
        s2_delta <= s1_delta;
        s2_qty <= sel_qty;
        s2_hit <= hit_any;
        s2_free <= free_any;
        s2_hit_way <= hit_way;
        s2_free_way <= free_way;
    end

    always_comb begin
        sum = $signed({1'b0, s2_qty}) + (QTY_W+1)'(s2_delta);

        add = ~s2_delta[DELTA_W-1];
        empties = s2_hit && (sum <= 0);
        applied = s2_hit || (add && s2_free);
        new_qty = s2_hit ? QTY_W'(sum) : QTY_W'(s2_delta);

        wr_en = '0;
        wr_idx = s2_idx;
        wr_data = '0;
        if (init_busy) begin
            wr_en = '1;
            wr_idx = init_idx;
        end else if (s2_valid) begin
            if (s2_hit) begin
                wr_en[s2_hit_way] = 1'b1;
                if (!empties) wr_data = {1'b1, s2_key, new_qty};
            end else if (add && s2_free) begin
                wr_en[s2_free_way] = 1'b1;
                wr_data = {1'b1, s2_key, new_qty};
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) occupancy <= '0;
        else if (s2_valid) begin
            if (!s2_hit && add && s2_free) occupancy <= occupancy + 1'b1;
            else if (empties) occupancy <= occupancy - 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            lvl_valid <= 1'b0;
            ovf_pulse <= 1'b0;
            miss_pulse <= 1'b0;
        end else begin
            lvl_valid <= s2_valid && applied;
            ovf_pulse <= s2_valid && add && !s2_hit && !s2_free;
            miss_pulse <= s2_valid && !add && !s2_hit;
        end
        lvl_sym <= s2_key[K_SYM +: 2];
        lvl_side <= s2_key[K_SIDE];
        lvl_price <= s2_key[K_PRICE +: 32];
        lvl_qty <= empties ? '0 : new_qty;
    end

endmodule

`default_nettype wire
