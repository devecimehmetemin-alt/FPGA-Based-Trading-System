`default_nettype none

// AXI4 read master that walks the DDR extents in order and streams their words out.

module axi_read_stream #(
    parameter int ADDR_W = 40,
    parameter int DATA_W = 128,
    parameter int ID_W = 4,
    parameter int NUM_EXTENTS = 2,
    parameter int BURST_BEATS = 16
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic start,
    input wire logic [NUM_EXTENTS-1:0][ADDR_W-1:0] ext_base,
    input wire logic [NUM_EXTENTS-1:0][31:0] ext_beats,
    input wire logic [$clog2(NUM_EXTENTS+1)-1:0] ext_count,
    input wire logic [15:0] space,
    output logic busy,
    output logic done,
    output logic [ID_W-1:0] m_axi_arid,
    output logic [ADDR_W-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic m_axi_arvalid,
    input wire logic m_axi_arready,
    input wire logic [DATA_W-1:0] m_axi_rdata,
    input wire logic [1:0] m_axi_rresp,
    input wire logic m_axi_rlast,
    input wire logic m_axi_rvalid,
    output logic m_axi_rready,
    output logic out_valid,
    output logic [DATA_W-1:0] out_data,
    input wire logic out_ready,
    output logic resp_err
);

    localparam int BYTES_PER_BEAT = DATA_W / 8;
    localparam int BURST_BYTES = BURST_BEATS * BYTES_PER_BEAT;
    localparam int EXT_W = $clog2(NUM_EXTENTS + 1);

    logic [EXT_W-1:0] ar_ext;
    logic [ADDR_W-1:0] ar_addr;
    logic [31:0] ar_left;
    logic [7:0] outstanding;
    logic [15:0] need;
    logic [EXT_W-1:0] next_ext, safe_ext;
    logic all_issued, ar_fire, r_fire, r_end, last_burst;

    assign all_issued = (ar_ext >= ext_count);
    assign need = ({8'd0, outstanding} + 16'd1) * 16'(BURST_BEATS);

    assign m_axi_arid = '0;
    assign m_axi_araddr = ar_addr;
    assign m_axi_arlen = 8'(BURST_BEATS - 1);
    assign m_axi_arsize = 3'($clog2(BYTES_PER_BEAT));
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = busy & ~all_issued & (ar_left != 32'd0) & (space >= need);
    assign m_axi_rready = out_ready;

    assign out_valid = m_axi_rvalid;
    assign out_data = m_axi_rdata;

    assign ar_fire = m_axi_arvalid & m_axi_arready;
    assign r_fire = m_axi_rvalid & m_axi_rready;
    assign r_end = r_fire & m_axi_rlast;
    assign last_burst = (ar_left <= 32'(BURST_BEATS));
    assign next_ext = ar_ext + 1'b1;
    assign safe_ext = (next_ext < EXT_W'(NUM_EXTENTS)) ? next_ext : '0;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            ar_ext <= '0;
            ar_addr <= '0;
            ar_left <= '0;
            outstanding <= '0;
            resp_err <= 1'b0;
        end else if (start & ~busy) begin
            busy <= 1'b1;
            done <= 1'b0;
            ar_ext <= '0;
            ar_addr <= ext_base[0];
            ar_left <= ext_beats[0];
            outstanding <= '0;
            resp_err <= 1'b0;
        end else begin
            if (ar_fire & ~r_end) outstanding <= outstanding + 8'd1;
            else if (~ar_fire & r_end) outstanding <= outstanding - 8'd1;

            if (ar_fire) begin
                if (last_burst) begin
                    ar_ext <= next_ext;
                    ar_addr <= ext_base[safe_ext];
                    ar_left <= (next_ext < ext_count) ? ext_beats[safe_ext] : '0;
                end else begin
                    ar_addr <= ar_addr + ADDR_W'(BURST_BYTES);
                    ar_left <= ar_left - 32'(BURST_BEATS);
                end
            end

            if (r_fire & (m_axi_rresp != 2'b00)) resp_err <= 1'b1;

            if (busy & all_issued & ~ar_fire & (outstanding == 8'd0)) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
