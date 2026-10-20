component extends="testbox.system.BaseSpec" {
    function run() {
        describe( "Calc", function() {
            it( "adds two numbers", function() {
                expect( new models.Calc().add( 2, 3 ) ).toBe( 5 );
            });
        });
    }
}